# frozen_string_literal: true

# Netdisco 全量配置备份；--help 查看并发、凭据、抽样和成功策略。
require_relative "boot"

exit Net::Connector::Netdisco::CLI::Backup.new(environment_defaults: true, default_config: File.expand_path("backup.yml", __dir__),
                                             default_directory: ENV["NC_BACKUP_DIRECTORY"] || File.expand_path("backups", __dir__)).run
