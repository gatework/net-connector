# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "open3"
require_relative "errors"

module Net
  module Connector
    # SSH 只写会话副本；认证后在跨进程锁内合并，网络等待不占用共享文件锁。
    class KnownHosts
      # 读取本次连接使用的私有主机密钥快照路径。
      attr_reader :path

      # 建立本次连接的私有主机密钥快照，初始化失败时清理已取得的资源。
      def initialize(configuration, replace: false)
        destination = configuration.known_hosts || File.join(Dir.home, ".ssh", "known_hosts")
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        @destination = File.join(File.realpath(File.dirname(destination)), File.basename(destination))
        @host = configuration.host
        @lock_timeout = configuration.login_timeout
        @host = "[#{@host}]:#{configuration.port}" if configuration.port && configuration.port != 22
        @replace = replace
        @original = read_shared
        create_snapshot
        @path = @file.path
        @file.write(@original)
        @file.flush
        remove_host(@path) if @replace
      rescue Exception # rubocop:disable Lint/RescueException -- 中断时也删除私有快照。
        close_preserving_failure
        raise
      end

      # 在目标文件锁内合并新增信任；检测并发密钥变化后原子写回。
      # 会话只写私有快照；登记时重读共享信任并检查冲突，避免并发连接覆盖已有主机密钥。
      def commit
        # 纯会话引擎加载不触及文件业务；实际登记信任时才加载持久化协议。
        require_relative "../storage/atomic_file"
        begin
          additions = File.binread(path).lines("\n") - @original.lines("\n")
          return if additions.empty?

          with_lock do
            current = read_shared
            Tempfile.create([".nc-known-hosts-merge-", ""], File.dirname(@destination)) do |file|
              file.write(current)
              file.flush
              reject_changed_key!(file.path) unless @replace
              remove_host(file.path) if @replace
              contents = merge_entries(File.binread(file.path), additions)
              Storage::AtomicFile.write(@destination, contents)
            ensure
              File.unlink(file.path + ".old") if file && File.exist?(file.path + ".old")
            end
          end
        rescue Storage::AtomicFile::WriteError => error
          # 已替换但目录未同步时报告完成边界，不能把新信任误当作尚未写入。
          raise ConnectionError.new(error.message, code: error.code, host: @host, phase: :login), cause: nil
        end
      end

      # 关闭并删除私有密钥快照，延迟取消直至清理完成。
      def close
        failure = nil
        # 清除引用至删除快照期间延后异步取消，不能留下失去所有者的临时文件。
        Thread.handle_interrupt(Exception => :never) do
          close_snapshot
        rescue Exception => error # rubocop:disable Lint/RescueException -- 保存同步清理故障，退出屏蔽范围后继续传播。
          failure = error
          raise
        end
      rescue Exception => error # rubocop:disable Lint/RescueException -- 延迟取消不能覆盖清理过程中已经发生的故障。
        raise failure || error, cause: nil
      end

      private

      # 保留已有条目和顺序；新增条目只登记一次，避免每条新增密钥扫描整份清单。
      def merge_entries(contents, additions)
        entries = contents.lines("\n")
        present = entries.each_with_object({}) { |line, index| index[line.freeze] = true }
        additions.each do |line|
          next if present.key?(line)

          entries << line
          present[line.freeze] = true
        end
        entries.map { |line| line.end_with?("\n") ? line : line + "\n" }.join("")
      end

      # 临时文件返回后先登记所有权，阻塞构造期间仍允许取消。
      def create_snapshot
        failure = nil
        begin
          Thread.handle_interrupt(Exception => :on_blocking) do
            @file = Tempfile.new([".nc-known-hosts-", ""], File.dirname(@destination))
          rescue Exception => error # rubocop:disable Lint/RescueException -- 构造故障先于退出屏蔽范围时递送的二次取消。
            failure = error
          end
        rescue Exception => error # rubocop:disable Lint/RescueException -- 成功交接后取消仍传播，但不覆盖已登记的构造故障。
          failure ||= error
        end
        raise failure, cause: nil if failure
      end

      # 清除快照引用并删除临时文件，清理错误不覆盖较早的失败。
      def close_snapshot
        file = @file
        @file = nil
        File.unlink(@path + ".old") if @path && File.exist?(@path + ".old")
      rescue Exception # rubocop:disable Lint/RescueException -- 删除附属文件失败或中断后仍须关闭私有快照。
        failed = true
        raise
      ensure
        begin
          file&.close!
        rescue Exception # rubocop:disable Lint/RescueException -- 私有快照清理不能覆盖先发生的删除故障。
          raise unless failed
        end
      end

      # 初始化失败时保留原始异常，同时尽力清理已经创建的临时文件。
      def close_preserving_failure
        close
      rescue Exception # rubocop:disable Lint/RescueException -- 不让清理异常覆盖初始化故障或用户中断。
        nil
      end

      # 通过同一安全文件描述符读取共享信任，文件缺失时视为空。
      def read_shared
        File.open(@destination, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          raise unsafe_file_error, cause: nil unless file.stat.file?

          file.read
        end
      rescue Errno::ENOENT
        ""
      rescue Errno::ELOOP, Errno::EISDIR, Errno::ENXIO
        raise unsafe_file_error, cause: nil
      end

      # 构造不暴露文件内容的主机密钥文件安全错误。
      def unsafe_file_error
        ConnectionError.new("known_hosts must be a managed regular file", code: :known_hosts_unsafe, host: @host, phase: :login)
      end

      # 核对最新共享信任与会话快照，拒绝并发登记期间出现的密钥变化。
      def reject_changed_key!(current_path)
        current = host_keys(current_path)
        staged = host_keys(path)
        return if current.empty? || (staged - current).empty?

        raise ConnectionError.new("host key changed during concurrent registration", code: :host_key_changed)
      end

      # 调用 ssh-keygen 查询当前主机的唯一公钥条目。
      def host_keys(path)
        output, status = Open3.capture2e("ssh-keygen", "-f", path, "-F", @host)
        raise IOError, "reading device host key failed" unless [0, 1].include?(status.exitstatus)

        output.lines("\n").reject { |line| line.start_with?("#") }.map { |line| line.split(" ")[1, 2] }.uniq
      end

      # 从指定快照中移除当前主机条目，不直接修改共享信任文件。
      def remove_host(path)
        _output, status = Open3.capture2e("ssh-keygen", "-f", path, "-R", @host)
        raise IOError, "removing device host key failed" unless status.success?
      end

      # 取得私有信任文件锁并核对目录项身份，串行合并并发登记。
      def with_lock
        lock_path = @destination + ".nc-lock"
        File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600) do |file|
          stat = file.stat
          unless stat.file? && stat.uid == Process.euid && stat.nlink == 1 && (stat.mode & 0o7777) == 0o600
            raise IOError, "known_hosts lock must be an owned private regular file"
          end
          acquire_lock(file)
          current = File.lstat(lock_path)
          raise IOError, "known_hosts lock changed" unless current.dev == stat.dev && current.ino == stat.ino

          yield
        end
      end

      # 认证后的合并另有有限等待；持锁进程卡住时保留共享信任并交由会话正常清理。
      def acquire_lock(file)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_timeout
        until file.flock(File::LOCK_EX | File::LOCK_NB)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            raise ConnectionError.new("known_hosts lock wait timed out", code: :known_hosts_busy, host: @host, phase: :login)
          end
          sleep [remaining, 0.01].min
        end
      end
    end
  end
end
