# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      # 报告是新的诊断通道：只接受固定词表，不展开异常消息、调用栈、命令、source 或 line。
      Diagnostic = Data.define(:error_code, :error_type, :phase, :underlying_type,
                               :artifact_state, :artifact_phase, :verification)

      class Diagnostic
        CONNECTOR_TYPES = %w[Error ConnectionError AuthenticationError LoginTimeout CommandTimeout WriteTimeout
                             PromptError ConnectionClosed TransportError DeviceError ScriptError InternalError
                             OutputLimitExceeded ScriptOutputLimitExceeded SessionBusy UnsupportedOperation LogError ParsingError BackupBusy
                             BackupPersistenceError TftpCompletionError SavedConfigChanged].freeze
        TYPES = (CONNECTOR_TYPES.map { |name| "Net::Connector::#{name}" } +
          %w[StandardError RuntimeError ArgumentError TypeError IOError EOFError SystemCallError ThreadError
             RangeError KeyError IndexError NoMethodError NameError FrozenError NotImplementedError
             Timeout::Error IO::TimeoutError Errno::EIO Errno::EACCES Errno::EPERM Errno::ENOSPC Errno::EROFS
             Errno::ENOENT Errno::ENOTDIR Errno::EISDIR Errno::ELOOP Errno::EINVAL Errno::ENOSYS
             Errno::ENOTSUP Errno::EOPNOTSUPP Errno::ETIMEDOUT Errno::ECONNREFUSED Errno::ECONNRESET
             Net::Connector::Operations::PrivateFile::WriteError
             Net::Connector::Operations::PrivateFile::PersistenceError
             Net::Connector::Operations::PrivateFile::DirectorySyncUnsupported]).freeze
        CODES = (CONNECTOR_TYPES.map { |name| name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym } +
          %i[authentication_failed connection_failed connection_refused no_route connection_reset
             connection_timeout host_key_changed host_key_untrusted rsa_too_small unsupported_cipher
             ambiguous_description ambiguous_neighbor confirmation_required description_stages_unsupported
             description_unconfirmed description_unsupported incomplete_configuration interface_missing
             neighbor_discovery_unsupported parse_failed invalid_output_encoding persistence_unconfirmed stale_plan startup_config_missing
             template_invalid template_missing template_unreadable transfer_failed transfer_finalize_failed
             transfer_path_mismatch transfer_path_unconfirmed transfer_unconfirmed uncommitted_configuration
             unrecognized_output unsupported_configuration_format verification_plan_changed candidate_isolation_unavailable
             backup_durability_unsupported backup_finalize_failed backup_persistence_unconfirmed
             file_finalize_failed file_persistence_unconfirmed file_write_failed directory_sync_unsupported]).freeze
        PHASES = %i[connect login enable command script read write close logging backup collect discover parse
                    plan apply verify persist tftp_backup report callback].freeze
        ARTIFACT_STATES = %i[not_committed committed durable reported_uploaded].freeze
        ARTIFACT_PHASES = %i[resolve_parent temporary_file write file_sync rename directory_open directory_sync
                            cleanup complete path finalize].freeze
        private_constant :CONNECTOR_TYPES, :TYPES, :CODES, :PHASES, :ARTIFACT_STATES, :ARTIFACT_PHASES

        # 包括手工构造的结果在内，v2 都不能携带自由文本诊断值。
        def initialize(error_code: nil, error_type: nil, phase: nil, underlying_type: nil,
                       artifact_state: nil, artifact_phase: nil, verification: nil)
          super(error_code: CODES.include?(error_code) ? error_code : nil,
                error_type: self.class.type(error_type), phase: PHASES.include?(phase) ? phase : nil,
                underlying_type: self.class.type(underlying_type),
                artifact_state: ARTIFACT_STATES.include?(artifact_state) ? artifact_state : nil,
                artifact_phase: ARTIFACT_PHASES.include?(artifact_phase) ? artifact_phase : nil,
                verification: verification == :device_reported ? verification : nil)
        end

        def self.type(name)
          return if name.nil?

          name.instance_of?(String) && TYPES.include?(name) ? name.dup.freeze : "StandardError"
        end

        # 读取已知错误的白名单属性后立即丢弃异常引用，不把回调对象保留进批次。
        def self.from(error, backup: nil, phase: nil)
          return unless error

          fields = { error_type: type(error.class.name) || "StandardError", phase: phase }
          if error.is_a?(Net::Connector::Error)
            fields.merge!(error_code: error.code, phase: phase || error.phase)
            fields[:underlying_type] = error.underlying.type if error.underlying.instance_of?(UnderlyingError)
          end
          new(**fields.merge(completion_fields(error, backup, phase)))
        rescue StandardError
          new(error_type: "StandardError", phase: phase)
        end

        def self.completion_fields(error, backup, phase)
          if error.instance_of?(BackupPersistenceError) && backup.instance_of?(Backup) && error.backup.equal?(backup)
            { artifact_state: error.receipt.state, artifact_phase: error.receipt.phase,
              underlying_type: error.underlying_type }
          elsif error.instance_of?(TftpCompletionError) && backup.instance_of?(TftpBackup) && error.transfer.equal?(backup)
            { artifact_state: :reported_uploaded, artifact_phase: error.code == :transfer_finalize_failed ? :finalize : :path,
              verification: :device_reported, underlying_type: error.underlying_type }
          elsif phase == :report && Operations::PrivateFile.receipt_error?(error)
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
