# frozen_string_literal: true

require "digest"
require_relative "private_file"
require_relative "backup_lock"
require_relative "safe_file"

module Net
  module Connector
    Backup = Data.define(:path, :bytes, :sha256, :collected_at, :change, :previous_sha256) do
      # 保存配置备份的路径、摘要和变更状态。
      def initialize(path:, bytes:, sha256:, collected_at:, change: nil, previous_sha256: nil)
        super
      end

      # 判断本次采集是否产生新的配置内容。
      def changed? = [:created, :changed].include?(change)
    end

    # 只携带库自身的提交回执和配置元数据，不携带正文或原始文件系统异常。
    class BackupPersistenceError < Error
      attr_reader :backup, :receipt, :underlying_type

      def initialize(backup:, write_error:, host: nil)
        unless backup.instance_of?(Backup) && Operations::PrivateFile.receipt_error?(write_error) &&
               write_error.receipt.committed? && write_error.receipt.path == backup.path
          raise ArgumentError, "backup persistence error requires a matching committed backup receipt"
        end

        @backup, @receipt = backup, write_error.receipt
        @underlying_type = write_error.underlying_type
        code = if write_error.instance_of?(Operations::PrivateFile::DirectorySyncUnsupported)
                 :backup_durability_unsupported
               elsif receipt.durable?
                 :backup_finalize_failed
               else
                 :backup_persistence_unconfirmed
               end
        super(write_error.message, code: code, host: host, phase: :backup)
      end
    end

    module Operations
      class LocalBackup
        # 保存执行配置采集的设备对象。
        def initialize(device) = @device = device

        # 采集配置、识别变更并原子写入私有文件。
        def call(path:, lock_timeout: 0)
          host = @device.host if @device.respond_to?(:host)
          BackupLock.synchronize(path, timeout: lock_timeout, host: host) { |lock| collect_and_write(lock.path) }
        end

        private

        def collect_and_write(destination)
          contents = @device.running_config.value!
          digest = Digest::SHA256.hexdigest(contents)
          previous = SafeFile.fingerprint(destination, missing: true, replace_symlink: true)
          previous_digest = previous&.sha256
          change = if previous_digest.nil?
                     :created
                   elsif previous_digest == digest
                     :unchanged
                   else
                     :changed
                   end

          backup = Backup.new(path: destination, bytes: contents.bytesize,
                              sha256: digest, collected_at: Time.now.utc, change: change,
                              previous_sha256: previous_digest)
          if change != :unchanged || previous.mode != 0o600 || !SafeFile.same_entry?(destination, previous)
            write_backup(backup, contents)
          end
          backup
        end

        def write_backup(backup, contents)
          PrivateFile.write_receipt(backup.path, contents)
        rescue PrivateFile::WriteError => error
          raise unless PrivateFile.receipt_error?(error) && error.receipt.committed?

          host = @device.host if @device.respond_to?(:host)
          raise BackupPersistenceError.new(backup: backup, write_error: error, host: host), cause: nil
        end
      end
    end
  end
end
