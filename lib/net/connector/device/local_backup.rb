# frozen_string_literal: true

require "digest"
require_relative "../engine/errors"
require_relative "../storage"

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
        unless backup.instance_of?(Backup) && Storage::PrivateFile.receipt_error?(write_error) &&
               write_error.receipt.committed? && write_error.receipt.path == backup.path
          raise ArgumentError, "backup persistence error requires a matching committed backup receipt"
        end

        @backup, @receipt = backup, write_error.receipt
        @underlying_type = write_error.underlying_type
        code = if write_error.instance_of?(Storage::PrivateFile::DirectorySyncUnsupported)
                 :backup_durability_unsupported
               elsif receipt.durable?
                 :backup_finalize_failed
               else
                 :backup_persistence_unconfirmed
               end
        super(write_error.message, code: code, host: host, phase: :backup)
      end
    end

    class LocalBackup
      # 设备入口与功能实现共置，Base 只组合能力，不重复业务流程。
      module Capability
        # 采集配置并以原子方式保存为私有文件。
        # 采集失败时保留已有备份文件。
        def backup(path:, lock_timeout: 0)
          @session.assert_path_lock_order!(:backup)
          LocalBackup.new(self).call(path: path, lock_timeout: lock_timeout)
        end
      end

      # 保存执行配置采集的设备对象。
      def initialize(device) = @device = device

      # 采集配置、识别变更并原子写入私有文件。
      def call(path:, lock_timeout: 0)
        host = @device.host if @device.respond_to?(:host)
        Storage::BackupLock.synchronize(path, timeout: lock_timeout, host: host) { |lock| collect_and_write(lock.path) }
      end

      private

      def collect_and_write(destination)
        contents = @device.running_config.value!
        digest = Digest::SHA256.hexdigest(contents)
        previous = Storage::SafeFile.fingerprint(destination, missing: true, replace_symlink: true)
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
        if change != :unchanged || previous.mode != 0o600 || !Storage::SafeFile.same_entry?(destination, previous)
          write_backup(backup, contents)
        end
        backup
      end

      def write_backup(backup, contents)
        Storage::PrivateFile.write(backup.path, contents)
      rescue Storage::PrivateFile::WriteError => error
        raise unless Storage::PrivateFile.receipt_error?(error) && error.receipt.committed?

        host = @device.host if @device.respond_to?(:host)
        raise BackupPersistenceError.new(backup: backup, write_error: error, host: host), cause: nil
      end
    end
  end
end
