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

        attr_reader :path

        def self.lock_path(path)
          destination = File.expand_path(path)
          directory = File.realpath(File.dirname(destination))
          # 锁名先折叠 Unicode 与大小写，避免大小写不敏感文件系统上的别名绕过互斥。
          # 在区分大小写的文件系统上可能保守地合并两个锁，但不会改写目标文件名。
          filename = File.basename(destination).b.force_encoding(Encoding::UTF_8)
          filename = filename.valid_encoding? ? filename.unicode_normalize(:nfc).downcase(:fold).unicode_normalize(:nfc) : filename.b.downcase
          File.join(directory, ".net-connector-#{Digest::SHA256.hexdigest(filename)}.lock")
        end

        def self.synchronize(path, **options, &) = new(path, **options).synchronize(&)

        def initialize(path, timeout: 0, host: nil)
          raise ArgumentError, "path must be a nonempty String" unless path.is_a?(String) && !path.empty?
          unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout >= 0 && timeout.to_f.finite?
            raise ArgumentError, "lock_timeout must be a nonnegative finite number"
          end

          @path = File.expand_path(path).freeze
          @lock_path = self.class.lock_path(@path).freeze
          @timeout, @host = timeout.to_f, host
        end

        def synchronize
          # Fleet 只向下层备份借用一次；消费后清除，采集回调中的递归备份仍须竞争锁。
          # Thread#[] 是 Fiber 局部存储；fork 后不能消费父进程的借用记录。
          if Thread.current[STORAGE_KEY] == [@lock_path, Process.pid]
            Thread.current[STORAGE_KEY] = nil
            return yield self
          end

          file = nil
          begin
            file = open_lock
            verify_lock!(file)
            acquire(file)
            verify_lock!(file)
            @owner = [Process.pid, Fiber.current]
            yield self
          ensure
            @owner = nil
            file&.close
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

        def open_lock
          File.open(@lock_path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600)
        rescue Errno::ELOOP, Errno::EISDIR, Errno::ENXIO
          raise ArgumentError, "backup lock must be a private regular file", cause: nil
        end

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

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        def wait(seconds) = sleep(seconds)
      end
    end
  end
end
