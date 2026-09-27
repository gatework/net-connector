# frozen_string_literal: true

# 检查 Netdisco 清单，然后把配置保存到 examples/backups/。
# 凭据通常从 README.md 所列的环境变量读取。
# 一次性运行可用 --stdin-credentials：先从标准输入读取 JSON 凭据，
# 再等待第二行输入 RUN，之后才连接设备。

require "json"
require "time"
require "fileutils"
require "tmpdir"
require "net/connector/netdisco"

File.umask(0o077)

settings = Net::Connector::Netdisco::Settings.new
if ARGV == ["--stdin-credentials"]
  begin
    input = JSON.parse(STDIN.gets || "")
  rescue JSON::ParserError
    abort "凭据 JSON 无效"
  end
  keys = %w[netdisco_username netdisco_password device_username device_password]
  raise ArgumentError, "需要四个非空凭据字符串" unless keys.all? { |key| input[key].is_a?(String) && !input[key].empty? }

  client = Net::Connector::Netdisco::Client.new(
    url: ENV.fetch("NETDISCO_URL"),
    username: input.fetch("netdisco_username"),
    password: input.fetch("netdisco_password")
  )
  credentials = lambda do |_device|
    { username: input.fetch("device_username"),
      password: input.fetch("device_password"),
      host_key_policy: :strict }
  end
elsif ARGV.empty?
  client = settings.client
  credentials = settings.method(:device_credentials_for)
else
  abort "用法：ruby -Ilib examples/netdisco_backup.rb [--stdin-credentials]"
end

rules = settings.rules
rows = client.devices
snapshot = Struct.new(:devices).new(rows)
fleet = Net::Connector::Netdisco::Fleet.new(client: snapshot, settings: settings,
                                            rules: rules, credentials: credentials)
sample_size = Integer(ENV.fetch("NET_CONNECTOR_SAMPLE_PER_VENDOR", "3"), 10)
raise ArgumentError, "每厂商抽样数量须在 1 至 5 之间" unless (1..5).cover?(sample_size)

backup_plan = fleet.plan_backup(limit_per_vendor: sample_size)
devices = backup_plan.inventory
selected = backup_plan.selected
plan = {
  total: devices.size,
  ready: devices.count(&:ready?),
  vendors: devices.group_by { |device| device.vendor || :unmapped }.transform_values(&:size),
  issues: devices.reject(&:ready?).group_by(&:issue).transform_values(&:size),
  selected: selected.map do |device|
    { host: device.host, name: device.name, vendor: device.vendor,
      backup_filename: device.backup_filename }
  end
}
puts JSON.generate(plan: plan)
$stdout.flush

if ARGV == ["--stdin-credentials"]
  abort "备份已取消" unless STDIN.gets&.strip == "RUN"
end

backup_root = File.join(__dir__, "backups")
FileUtils.mkdir_p(backup_root, mode: 0o700)
directory = Dir.mktmpdir("#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-", backup_root)
batch = fleet.backup_all(directory: directory, concurrency: settings.concurrency, plan: backup_plan)
summary = batch.summary
summary.delete(:devices)
summary.merge!(report_location: batch.report_location, report_error: batch.report_error,
               outcomes: batch.outcomes.map do |outcome|
                 {
                   host: outcome.device.host,
                   name: outcome.device.name,
                   source_ip: outcome.device.source_ip,
                   vendor: outcome.device.vendor,
                   status: outcome.status,
                   backup: outcome.backup&.path,
                   bytes: outcome.backup&.bytes,
                   sha256: outcome.backup&.sha256,
                   change: outcome.backup&.change,
                   previous_sha256: outcome.backup&.previous_sha256,
                   started_at: outcome.started_at&.iso8601,
                   finished_at: outcome.finished_at&.iso8601,
                   duration_ms: outcome.duration_ms,
                   error_code: outcome.error_code,
                   error_type: outcome.error_type
                 }
               end)
File.write(File.join(directory, "summary.json"), JSON.pretty_generate(summary))
tasks_succeeded = !backup_plan.ready.empty? && backup_plan.ready.all? { |index, _device| batch.outcomes.fetch(index).success? }
tasks_succeeded &&= batch.callback_errors.empty? && batch.report_error.nil?
puts JSON.generate(directory: directory, counts: batch.counts, tasks_succeeded: tasks_succeeded,
                   report_location: batch.report_location, report_error: batch.report_error)
exit(tasks_succeeded ? 0 : 1)
