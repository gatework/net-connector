# frozen_string_literal: true

# 设备原生 TFTP 导出；--tftp-root 指定本机服务器文件目录。
require_relative "boot"

exit Net::Connector::Netdisco::CLI::Backup.new(mode: :tftp).run
