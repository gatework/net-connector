# frozen_string_literal: true

# 设备原生 TFTP 导出；--tftp-root 指定本机服务器文件目录。
require_relative "boot"

exit Net::Connector::Netdisco::CLI::Backup.new(environment_defaults: true, mode: :tftp, default_config: File.expand_path("backup.yml", __dir__),
                                             default_directory: ENV["NC_BACKUP_DIRECTORY"] || File.expand_path("backups", __dir__)).run
