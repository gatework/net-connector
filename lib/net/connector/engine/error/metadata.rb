# frozen_string_literal: true

require_relative "../errors"

module Net
  module Connector
    class Error
      # 日志与报告共用固定诊断词表；未知元数据可能来自配置正文，不能作为自由文本输出。
      module Metadata
        CONNECTOR_TYPES = %w[Error ConnectionError AuthenticationError LoginTimeout CommandTimeout WriteTimeout
                             PromptError ConnectionClosed TransportError DeviceError ConfigurationError ScriptError InternalError
                             OutputLimitExceeded ScriptOutputLimitExceeded SessionBusy UnsupportedOperation LogError ParsingError BackupBusy
                             BackupPersistenceError BackupFinalizeError TftpCompletionError].freeze
        TYPES = (CONNECTOR_TYPES.map { |name| "Net::Connector::#{name}" } +
          %w[StandardError RuntimeError ArgumentError TypeError IOError EOFError SystemCallError ThreadError
             RangeError KeyError IndexError NoMethodError NameError FrozenError NotImplementedError
             Timeout::Error IO::TimeoutError Errno::EIO Errno::EACCES Errno::EPERM Errno::ENOSPC Errno::EROFS
             Errno::ENOENT Errno::ENOTDIR Errno::EISDIR Errno::ELOOP Errno::EINVAL Errno::ENOSYS
             Errno::EMFILE Errno::ENFILE Errno::ENOMEM Errno::EAGAIN
             Errno::ENOTSUP Errno::EOPNOTSUPP Errno::ETIMEDOUT Errno::ECONNREFUSED Errno::ECONNRESET
             Net::Connector::RemoteBackup::CompletionError
             Net::Connector::Storage::AtomicFile::WriteError
             Net::Connector::Storage::AtomicFile::PersistenceError
             Net::Connector::Storage::AtomicFile::DirectorySyncUnsupported
             Net::Connector::Netdisco::Tftp::Archive::Unavailable Net::Connector::Netdisco::Tftp::Archive::Failure]).freeze
        CODES = (CONNECTOR_TYPES.map { |name| name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym } +
          %i[authentication_failed connection_failed connection_refused no_route connection_reset
             connection_timeout host_key_changed host_key_untrusted known_hosts_busy known_hosts_unsafe known_hosts_inherited
             rsa_too_small unsupported_cipher
             ambiguous_description ambiguous_neighbor confirmation_required description_stages_unsupported
             description_unconfirmed description_unsupported incomplete_configuration interface_missing
             neighbor_discovery_unsupported parse_failed invalid_output_encoding persistence_unconfirmed stale_plan startup_config_missing
             template_invalid template_missing template_unreadable transfer_failed transfer_finalize_failed
             transfer_path_mismatch transfer_path_unconfirmed transfer_unconfirmed uncommitted_configuration
             unrecognized_output unsupported_configuration_format verification_plan_changed candidate_isolation_unavailable
             backup_durability_unsupported backup_finalize_failed backup_persistence_unconfirmed
             file_finalize_failed file_persistence_unconfirmed file_write_failed directory_sync_unsupported
             tftp_history_unavailable tftp_archive_failed]).freeze
        PHASES = %i[connect login enable command script read write close logging backup collect discover parse
                    plan apply verify persist save interact tftp_backup remote_backup report callback].freeze
        private_constant :CONNECTOR_TYPES, :TYPES, :CODES, :PHASES

        module_function

        # 仅接受白名单错误码，过滤任意外部诊断文本。
        def code(value) = CODES.include?(value) ? value : nil

        # 仅接受已声明的执行阶段，未知阶段返回空值。
        def phase(value) = PHASES.include?(value) ? value : nil

        # 判断类型名是否为库允许公开的异常名称。
        def known_type?(name) = name.instance_of?(String) && TYPES.include?(name)

        # 显示名白名单不授予复制私有字段的权限；外部子类可以重写 Class.name。
        def trusted_error_class?(type)
          name = type.name
          known_type?(name) && Object.const_get(name).equal?(type)
        rescue NameError
          false
        end

        # 将已知异常类型复制为安全文本，未知类型统一归为普通错误。
        def type(name)
          return if name.nil?

          known_type?(name) ? name.dup.freeze : "StandardError"
        end
      end
    end
  end
end
