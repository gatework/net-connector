# frozen_string_literal: true

# 单设备 TFTP 目标由命令行指定；登录凭据从 NC_ 环境变量读取。
require "optparse"

values = {}
parser = OptionParser.new do |options|
  options.banner = "用法：ruby device_tftp.rb --vendor VENDOR --host HOST --server SERVER [选项]"
  { "--vendor VENDOR" => :vendor, "--host HOST" => :host, "--server SERVER" => :server,
    "--source-file FILE" => :source_file, "--path PATH" => :path, "--vrf VRF" => :vrf }.each do |flag, key|
    options.on(flag) { |value| values[key] = value }
  end
  options.on("-h", "--help", "凭据：NC_DEVICE_USERNAME、NC_DEVICE_PASSWORD") { puts options; exit }
end
begin
  parser.parse!
  raise OptionParser::InvalidArgument unless ARGV.empty? && %i[vendor host server].all? { |key| values[key] && !values[key].empty? }
rescue OptionParser::ParseError
  abort parser.to_s
end

require_relative "boot"
require "net/connector"
require "json"
require "time"

vendor = values.fetch(:vendor).to_sym
device_host = values.fetch(:host)
transfer = values.slice(:source_file, :path, :vrf).merge(host: values.fetch(:server))
Net::Connector.open(vendor, host: device_host,
                    username: ENV.fetch("NC_DEVICE_USERNAME"),
                    password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  result = device.tftp_backup(**transfer)
  puts JSON.generate(device: device_host, vendor: vendor, server: result.server,
                     path: result.path, completed_at: result.completed_at.utc.iso8601)
end
