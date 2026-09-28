# frozen_string_literal: true

# Netdisco 全量配置备份；--help 查看并发、凭据、抽样和成功策略。
require_relative "boot"
require "net/connector/netdisco"

exit Net::Connector::Netdisco::BackupRun.new.run
