# frozen_string_literal: true

module Net
  module Connector
    # 文件存储不依赖设备连接；备份、离线导出和批量报告共享这些原语。
    module Storage
      autoload :BatchDirectory, File.expand_path("storage/batch_directory", __dir__)
      autoload :BackupLock, File.expand_path("storage/backup_lock", __dir__)
      autoload :AtomicFile, File.expand_path("storage/atomic_file", __dir__)
      autoload :FileReader, File.expand_path("storage/file_reader", __dir__)
      autoload :SavedConfig, File.expand_path("storage/saved_config", __dir__)
    end

    autoload :BackupBusy, File.expand_path("storage/backup_lock", __dir__)
  end
end
