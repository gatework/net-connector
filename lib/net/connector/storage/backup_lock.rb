# frozen_string_literal: true

require "digest"
require_relative "../engine/errors"

module Net
  module Connector
    class BackupBusy < Error; end

    module Storage
      # 路径锁在设备采集之前取得；锁文件长期保留，避免等待者落在已经删除的 inode 上。
      class BackupLock
        STORAGE_KEY = :net_connector_backup_delegation
        private_constant :STORAGE_KEY

        # 读取当前路径锁对应的绝对备份目标路径。
        attr_reader :path

        # 解析真实父目录并规范化文件名，以稳定摘要生成跨会话互斥锁路径。
        def self.lock_path(path)
          destination = File.expand_path(path)
          directory = File.realpath(File.dirname(destination))
          # 锁名先折叠 Unicode 与大小写，避免大小写不敏感文件系统上的别名绕过互斥。
          # 在区分大小写的文件系统上可能保守地合并两个锁，但不会改写目标文件名。
          filename = File.basename(destination).b.force_encoding(Encoding::UTF_8)
          filename = filename.valid_encoding? ? filename.unicode_normalize(:nfc).downcase(:fold).unicode_normalize(:nfc) : filename.b.downcase
          File.join(directory, ".net-connector-#{Digest::SHA256.hexdigest(filename)}.lock")
        end

        # 在目标路径锁内执行块并统一回收锁文件句柄。
        # 锁覆盖采集和文件提交全过程；借用授权只消费一次，采集回调内的递归操作仍须重新竞争。
        def self.synchronize(path, **options, &) = new(path, **options).synchronize(&)

        # 校验目标路径和有限等待时间，预先固定目标及锁路径。
        def initialize(path, timeout: 0, host: nil)
          raise ArgumentError, "path must be a nonempty String" unless path.is_a?(String) && !path.empty?
          unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout >= 0 && timeout.to_f.finite?
            raise ArgumentError, "lock_timeout must be a nonnegative finite number"
          end

          @path = File.expand_path(path).freeze
          @lock_path = self.class.lock_path(@path).freeze
          @timeout, @host = timeout.to_f, host
        end

        # 取得并验证目标锁后执行备份，只有同一 Fiber 获授权时可借用一次已有锁。
        # 锁覆盖采集和文件提交全过程；借用授权只消费一次，采集回调内的递归操作仍须重新竞争。
        def synchronize
          # Fleet 只向下层备份借用一次；消费后清除，采集回调中的递归备份仍须竞争锁。
          # Thread#[] 是 Fiber 局部存储；fork 后不能消费父进程的借用记录。
          if Thread.current[STORAGE_KEY] == [@lock_path, Process.pid]
            Thread.current[STORAGE_KEY] = nil
            return yield self
          end

          file = acquisition_error = nil
          begin
            # 文件取得与所有权登记不可拆开；竞争锁和业务块仍立即响应中断。
            Thread.handle_interrupt(Exception => :never) do
              begin
                file = open_lock
              rescue Exception => error # rubocop:disable Lint/RescueException -- 取得失败先于边界退出时递送的中断。
                acquisition_error = error
              end
            end
            raise acquisition_error, cause: nil if acquisition_error

            verify_lock!(file)
            acquire(file)
            verify_lock!(file)
            @owner = [Process.pid, Fiber.current]
            yield self
          rescue Exception # rubocop:disable Lint/RescueException -- 解锁收尾保留首个操作故障或中断。
            failed = true
            raise acquisition_error, cause: nil if acquisition_error

            raise
          ensure
            @owner = nil
            cleanup_error = nil
            begin
              Thread.handle_interrupt(Exception => :never) do
                begin
                  file&.close
                rescue Exception => error # rubocop:disable Lint/RescueException -- 在递送待处理中断前登记关闭故障。
                  cleanup_error = error
                end
              end
            rescue Exception => error # rubocop:disable Lint/RescueException -- 待处理中断不能覆盖已登记的关闭故障。
              cleanup_error ||= error
            end
            raise cleanup_error, cause: nil if cleanup_error && !failed
          end
        end

        # 仅持有实际 flock 的同一 Fiber 可授权一次内层采集，避免把路径锁变成任意可重入锁。
        def with_delegated_lock
          raise ThreadError, "backup path delegation requires lock ownership" unless @owner == [Process.pid, Fiber.current]

          previous = Thread.current[STORAGE_KEY]
          begin
            Thread.current[STORAGE_KEY] = [@lock_path, Process.pid]
            yield
          ensure
            Thread.current[STORAGE_KEY] = previous
          end
        end

        private

        # 以不跟随符号链接的方式打开私有锁文件，拒绝危险文件类型。
        def open_lock
          File.open(@lock_path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600)
        rescue Errno::ELOOP, Errno::EISDIR, Errno::ENXIO
          raise ArgumentError, "backup lock must be a private regular file", cause: nil
        end

        # 核对锁为当前用户所有的单链接 0600 文件，且路径仍指向同一 inode。
        def verify_lock!(file)
          stat = file.stat
          unless stat.file? && stat.uid == Process.euid && stat.nlink == 1 && (stat.mode & 0o7777) == 0o600
            raise ArgumentError, "backup lock must be an owned regular file with mode 0600 and one link"
          end
          current = File.lstat(@lock_path)
          unless current.file? && current.dev == stat.dev && current.ino == stat.ino
            raise ArgumentError, "backup lock path changed while acquiring ownership"
          end
        rescue Errno::ENOENT
          raise ArgumentError, "backup lock path changed while acquiring ownership", cause: nil
        end

        # 非阻塞尝试取得文件独占锁，在有限时间内等待且不执行设备操作。
        def acquire(file)
          deadline = monotonic + @timeout
          loop do
            acquired = file.flock(File::LOCK_EX | File::LOCK_NB)
            return if acquired && (@timeout.zero? || monotonic < deadline)

            remaining = deadline - monotonic
            if remaining <= 0
              raise BackupBusy.new("backup path already belongs to another operation", host: @host, phase: :backup), cause: nil
            end
            wait([remaining, 0.05].min)
          end
        end

        # 读取单调时钟秒数，避免系统校时影响期限与耗时计算。
        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # 等待下一次锁竞争尝试，将轮询与单调时钟期限分开。
        def wait(seconds) = sleep(seconds)
      end
    end
  end
end
