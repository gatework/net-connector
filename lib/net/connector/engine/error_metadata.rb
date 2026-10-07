# frozen_string_literal: true

module Net
  module Connector
    # 日志与报告共用固定诊断词表；未知元数据可能来自配置正文，不能作为自由文本输出。
    module ErrorMetadata
      CONNECTOR_TYPES = %w[Error ConnectionError AuthenticationError LoginTimeout CommandTimeout WriteTimeout
                           PromptError ConnectionClosed TransportError DeviceError ScriptError InternalError
                           OutputLimitExceeded ScriptOutputLimitExceeded SessionBusy UnsupportedOperation LogError ParsingError BackupBusy
                           BackupPersistenceError TftpCompletionError].freeze
      TYPES = (CONNECTOR_TYPES.map { |name| "Net::Connector::#{name}" } +
        %w[StandardError RuntimeError ArgumentError TypeError IOError EOFError SystemCallError ThreadError
           RangeError KeyError IndexError NoMethodError NameError FrozenError NotImplementedError
           Timeout::Error IO::TimeoutError Errno::EIO Errno::EACCES Errno::EPERM Errno::ENOSPC Errno::EROFS
           Errno::ENOENT Errno::ENOTDIR Errno::EISDIR Errno::ELOOP Errno::EINVAL Errno::ENOSYS
           Errno::ENOTSUP Errno::EOPNOTSUPP Errno::ETIMEDOUT Errno::ECONNREFUSED Errno::ECONNRESET
           Net::Connector::Storage::PrivateFile::WriteError
           Net::Connector::Storage::PrivateFile::PersistenceError
           Net::Connector::Storage::PrivateFile::DirectorySyncUnsupported
           Net::Connector::Netdisco::TftpArchive::Unavailable Net::Connector::Netdisco::TftpArchive::ArchiveFailed]).freeze
      CODES = (CONNECTOR_TYPES.map { |name| name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym } +
        %i[authentication_failed connection_failed connection_refused no_route connection_reset
           connection_timeout host_key_changed host_key_untrusted known_hosts_busy rsa_too_small unsupported_cipher
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
                  plan apply verify persist save interact tftp_backup report callback].freeze
      private_constant :CONNECTOR_TYPES, :TYPES, :CODES, :PHASES

      module_function

      def code(value) = CODES.include?(value) ? value : nil

      def phase(value) = PHASES.include?(value) ? value : nil

      def known_type?(name) = name.instance_of?(String) && TYPES.include?(name)

      def type(name)
        return if name.nil?

        known_type?(name) ? name.dup.freeze : "StandardError"
      end
    end
  end
end
