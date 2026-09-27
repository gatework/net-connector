# frozen_string_literal: true

# Topology 同时是扩展策略的命名空间。显式装配公共定义，确保旧扩展先加载
# topology/strategy 时，已有常量不会阻止工作流加载；TextFSM 仍延迟到实际解析。
require_relative "operations/topology"

module Net
  module Connector
    module Operations
      autoload :RunningConfig, File.expand_path("operations/running_config", __dir__)
      autoload :ParseOutput, File.expand_path("operations/parse_output", __dir__)
      autoload :LocalBackup, File.expand_path("operations/local_backup", __dir__)
      autoload :BackupLock, File.expand_path("operations/backup_lock", __dir__)
      autoload :TftpBackup, File.expand_path("operations/tftp_backup", __dir__)
      autoload :Tftp, File.expand_path("operations/tftp/strategy", __dir__)
    end
    autoload :TftpTarget, File.expand_path("operations/tftp_backup", __dir__)
    autoload :TftpBackup, File.expand_path("operations/tftp_backup", __dir__)
    autoload :TftpReceipt, File.expand_path("operations/tftp_receipt", __dir__)
    autoload :TftpCompletionError, File.expand_path("operations/tftp_receipt", __dir__)
    autoload :Backup, File.expand_path("operations/local_backup", __dir__)
    autoload :BackupPersistenceError, File.expand_path("operations/local_backup", __dir__)
    autoload :BackupBusy, File.expand_path("operations/backup_lock", __dir__)
    autoload :SavedConfigChanged, File.expand_path("operations/saved_config/legacy_index", __dir__)
  end
end
