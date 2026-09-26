# frozen_string_literal: true

# 由设备发起原生配置备份；运行前通过环境变量设置设备和目标服务器。
require "json"
require "time"
require "net/connector"

vendor = ENV.fetch("DEVICE_VENDOR").to_sym
device_host = ENV.fetch("DEVICE_HOST")
server = ENV.fetch("TFTP_HOST")
options = { host: server }
options[:path] = ENV["TFTP_PATH"] if ENV.key?("TFTP_PATH")
options[:source_file] = ENV["TFTP_SOURCE_FILE"] if ENV.key?("TFTP_SOURCE_FILE")
options[:vrf] = ENV["TFTP_VRF"] if ENV.key?("TFTP_VRF")

Net::Connector.open(vendor, host: device_host,
                    username: ENV.fetch("DEVICE_USERNAME"),
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  result = device.tftp_backup(**options)
  puts JSON.generate(device: device_host, vendor: vendor, server: result.server,
                     path: result.path, completed_at: result.completed_at.utc.iso8601)
end
