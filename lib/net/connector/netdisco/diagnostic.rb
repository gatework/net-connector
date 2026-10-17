# frozen_string_literal: true

require_relative "../engine/error/metadata"
require_relative "../engine/errors"
require_relative "../device/local_backup"
require_relative "../device/tftp/receipt"
require_relative "../storage/atomic_file"

module Net
  module Connector
    module Netdisco
      # 报告是新的诊断通道：只接受固定词表，不展开异常消息、调用栈、命令、source 或 line。
      Diagnostic = Data.define(:error_code, :error_type, :phase, :underlying_type,
                               :artifact_state, :artifact_phase, :verification)

      class Diagnostic
        ARTIFACT_STATES = %i[not_committed committed durable reported_uploaded].freeze
        ARTIFACT_PHASES = %i[resolve_parent temporary_file write file_sync rename directory_open directory_sync
                            cleanup complete path finalize].freeze
        private_constant :ARTIFACT_STATES, :ARTIFACT_PHASES

        # 包括手工构造的结果在内，v2 都不能携带自由文本诊断值。
        def initialize(error_code: nil, error_type: nil, phase: nil, underlying_type: nil,
                       artifact_state: nil, artifact_phase: nil, verification: nil)
          super(error_code: Error::Metadata.code(error_code),
                error_type: Error::Metadata.type(error_type), phase: Error::Metadata.phase(phase),
                underlying_type: Error::Metadata.type(underlying_type),
                artifact_state: ARTIFACT_STATES.include?(artifact_state) ? artifact_state : nil,
                artifact_phase: ARTIFACT_PHASES.include?(artifact_phase) ? artifact_phase : nil,
                verification: verification == :device_reported ? verification : nil)
        end

        # 更新也经过初始化白名单；Ruby 3.2 的原生 Data#with 会跳过这一边界。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        # 读取已知错误的白名单属性后立即丢弃异常引用，不把回调对象保留进批次。
        def self.from(error, backup: nil, phase: nil)
          return unless error

          fields = { error_type: Error::Metadata.type(error.class.name) || "StandardError", phase: phase }
          if error.is_a?(Net::Connector::Error)
            fields.merge!(error_code: error.code, phase: phase || error.phase)
            fields[:underlying_type] = error.underlying.type if error.underlying.instance_of?(UnderlyingError)
          end
          new(**fields.merge(completion_fields(error, backup, phase)))
        rescue StandardError
          new(error_type: "StandardError", phase: phase)
        end

        # 只有本库错误与匹配的业务回执才能证明提交状态，不能采信任意对象自报成功。
        def self.completion_fields(error, backup, phase)
          if error.instance_of?(BackupPersistenceError) && backup.instance_of?(Backup) && error.backup.equal?(backup)
            { artifact_state: error.receipt.state, artifact_phase: error.receipt.phase,
              underlying_type: error.underlying_type }
          elsif error.instance_of?(BackupFinalizeError) && backup.instance_of?(Backup) && error.backup.equal?(backup)
            { artifact_phase: :finalize, underlying_type: error.underlying_type }
          elsif error.instance_of?(TftpCompletionError) && backup.instance_of?(TftpReceipt) && error.receipt.equal?(backup)
            { artifact_state: :reported_uploaded, artifact_phase: error.code == :transfer_finalize_failed ? :finalize : :path,
              verification: :device_reported, underlying_type: error.underlying_type }
          elsif phase == :report && Storage::AtomicFile.receipt_error?(error)
            { error_code: error.code, artifact_state: error.receipt.state, artifact_phase: error.receipt.phase,
              underlying_type: error.underlying_type }
          else
            {}
          end
        end
        private_class_method :completion_fields
      end
    end
  end
end
