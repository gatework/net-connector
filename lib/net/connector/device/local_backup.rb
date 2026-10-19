# frozen_string_literal: true

require "digest"
require_relative "../engine/errors"
require_relative "../storage"

module Net
  module Connector
    Backup = Data.define(:path, :bytes, :sha256, :collected_at, :change, :previous_sha256) do
      # 完成回执拥有自己的元数据；调用方和结果回调不能原地改写已保存文件的证据。
      def initialize(path:, bytes:, sha256:, collected_at:, change: nil, previous_sha256: nil)
        super(path: path&.dup&.freeze, bytes: bytes, sha256: sha256&.dup&.freeze,
              collected_at: collected_at&.dup&.freeze, change: change, previous_sha256: previous_sha256&.dup&.freeze)
      end

      # Ruby 3.2 的原生 Data#with 不调用初始化；更新也须重新复制并冻结元数据。
      def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

      # 判断本次采集是否产生新的配置内容。
      def changed? = [:created, :changed].include?(change)
    end

    # 只携带库自身的提交回执和配置元数据，不携带正文或原始文件系统异常。
    class BackupPersistenceError < Error
      # 读取已提交备份、写入回执及受控底层故障类型。
      attr_reader :backup, :receipt, :underlying_type

      # 校验已提交文件回执与备份路径，构造携带产物的持久化错误。
      def initialize(backup:, write_error:, host: nil)
        unless backup.instance_of?(Backup) && Storage::AtomicFile.receipt_error?(write_error) &&
               write_error.receipt.committed? && write_error.receipt.path == backup.path
          raise ArgumentError, "backup persistence error requires a matching committed backup receipt"
        end

        @backup, @receipt = backup, write_error.receipt
        @underlying_type = write_error.underlying_type
        code = if write_error.instance_of?(Storage::AtomicFile::DirectorySyncUnsupported)
                 :backup_durability_unsupported
               elsif receipt.durable?
                 :backup_finalize_failed
               else
                 :backup_persistence_unconfirmed
               end
        super(write_error.message, code: code, host: host, phase: :backup)
      end
    end

    # 备份已完成后的路径锁收尾错误；不把未变文件冒充本次完成 fsync 的写入回执。
    class BackupFinalizeError < Error
      # 读取已完成备份及其路径锁收尾故障类型。
      attr_reader :backup, :underlying_type

      # 保留已完成备份，记录路径锁收尾失败的受控类型。
      def initialize(backup:, underlying:, host: nil)
        raise ArgumentError, "backup must be a completed Backup" unless backup.instance_of?(Backup)

        @backup = backup
        @underlying_type = Error::Metadata.type(underlying.class.name) || "StandardError"
        super("backup completed; path lock finalization failed", code: :backup_finalize_failed, host: host, phase: :backup)
      end
    end

    # 先取得路径锁再采集和原子写入；提交后的收尾错误仍保留备份元数据。
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
        backup = nil
        host = @device.host if @device.respond_to?(:host)
        Storage::BackupLock.synchronize(path, timeout: lock_timeout, host: host) { |lock| backup = collect_and_write(lock.path) }
      rescue StandardError => error
        raise unless backup

        raise BackupFinalizeError.new(backup: backup, underlying: error, host: host), cause: nil
      end

      private

      # 采集配置并比较旧文件摘要，仅在内容或文件安全状态变化时原子替换。
      def collect_and_write(destination)
        contents = @device.running_config.value!
        digest = Digest::SHA256.hexdigest(contents)
        previous = Storage::FileReader.fingerprint(destination, missing: true, replace_symlink: true)
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
        # 内容未变也须核对权限与目录项身份；只在两者仍有效时保留原文件和 mtime。
        if change != :unchanged || previous.mode != 0o600 || !Storage::FileReader.same_entry?(destination, previous)
          write_backup(backup, contents)
        end
        backup
      end

      # 替换后失败仍交付已提交的备份回执，不能让调用方误判为没有产物。
      def write_backup(backup, contents)
        Storage::AtomicFile.write(backup.path, contents)
      rescue Storage::AtomicFile::WriteError => error
        raise unless Storage::AtomicFile.receipt_error?(error) && error.receipt.committed?

        host = @device.host if @device.respond_to?(:host)
        raise BackupPersistenceError.new(backup: backup, write_error: error, host: host), cause: nil
      end
    end
  end
end
