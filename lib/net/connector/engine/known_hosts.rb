# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "open3"
require_relative "errors"

module Net
  module Connector
    # SSH 只写会话副本；认证后在跨进程锁内合并，网络等待不占用共享文件锁。
    class KnownHosts
      attr_reader :path

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

      def commit
        additions = File.binread(path).lines("\n") - @original.lines("\n")
        return if additions.empty?

        with_lock do
          current = read_shared
          Tempfile.create([".nc-known-hosts-merge-", ""], File.dirname(@destination)) do |file|
            file.write(current)
            file.flush
            reject_changed_key!(file.path) unless @replace
            remove_host(file.path) if @replace
            contents = File.binread(file.path)
            entries = contents.lines("\n")
            additions.each { |line| entries << line unless entries.include?(line) }
            File.open(file.path, "wb", 0o600) do |replacement|
              replacement.write(entries.map { |line| line.end_with?("\n") ? line : line + "\n" }.join(""))
              replacement.flush
              replacement.fsync
            end
            File.rename(file.path, @destination)
          ensure
            File.unlink(file.path + ".old") if file && File.exist?(file.path + ".old")
          end
        end
      end

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

      def read_shared
        File.open(@destination, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          raise IOError, "known_hosts must be a regular file" unless file.stat.file?

          file.read
        end
      rescue Errno::ENOENT
        ""
      end

      def reject_changed_key!(current_path)
        current = host_keys(current_path)
        staged = host_keys(path)
        return if current.empty? || (staged - current).empty?

        raise ConnectionError.new("host key changed during concurrent registration", code: :host_key_changed)
      end

      def host_keys(path)
        output, status = Open3.capture2e("ssh-keygen", "-f", path, "-F", @host)
        raise IOError, "reading device host key failed" unless [0, 1].include?(status.exitstatus)

        output.lines("\n").reject { |line| line.start_with?("#") }.map { |line| line.split[1, 2] }.uniq
      end

      def remove_host(path)
        _output, status = Open3.capture2e("ssh-keygen", "-f", path, "-R", @host)
        raise IOError, "removing device host key failed" unless status.success?
      end

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
