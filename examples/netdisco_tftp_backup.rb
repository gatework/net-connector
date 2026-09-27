# frozen_string_literal: true

# 从 Netdisco 清单选择少量样本或全部就绪设备，执行原生 TFTP 导出。
# --stdin-credentials 使一次性凭据无需出现在命令参数或环境变量中。

require "json"
require "time"
require "fileutils"
require "digest"
require "open3"
require "socket"
require "tmpdir"
require "net/connector/netdisco"

File.umask(0o077)
server = ENV.fetch("TFTP_HOST")
local_server = Socket.ip_address_list.any? { |address| address.ip_address == server }
local_tftp_root = if ENV.key?("TFTP_ROOT")
                    File.expand_path(ENV.fetch("TFTP_ROOT"))
                  elsif local_server
                    File.join(Dir.home, "Documents", "TFTP")
                  end
Net::Connector::TftpTarget.new(host: server, path: "preflight.cfg")
sample_size = Integer(ENV.fetch("NET_CONNECTOR_SAMPLE_PER_VENDOR", "5"), 10)
raise ArgumentError, "每厂商抽样数量须在 1 至 5 之间" unless (1..5).cover?(sample_size)
all_devices = ENV.fetch("NET_CONNECTOR_ALL", "0") == "1"

backup_root = File.join(__dir__, "backups")
FileUtils.mkdir_p(backup_root, mode: 0o700)
directory = Dir.mktmpdir("#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-", backup_root)
example_env = ENV.to_h.merge(
  "NET_CONNECTOR_LOG_DIRECTORY" => File.join(directory, "logs"),
  "NET_CONNECTOR_LOG_LEVEL" => ENV.fetch("NET_CONNECTOR_LOG_LEVEL", "debug")
)
example_env["NET_CONNECTOR_CONCURRENCY"] ||= "50" if all_devices
settings = Net::Connector::Netdisco::Settings.new(
  env: example_env
)
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
    { username: input.fetch("device_username"), password: input.fetch("device_password"),
      host_key_policy: :strict, log_level: ENV.fetch("NET_CONNECTOR_LOG_LEVEL", "debug").to_sym }
  end
elsif ARGV.empty?
  client = settings.client
  credentials = settings.method(:credentials_for)
else
  abort "用法：ruby -Ilib examples/netdisco_tftp_backup.rb [--stdin-credentials]"
end

rows = client.devices
snapshot = Struct.new(:devices).new(rows)
fleet = Net::Connector::Netdisco::Fleet.new(client: snapshot, settings: settings,
                                            rules: settings.rules, credentials: credentials)
backup_plan = fleet.plan_tftp_backup(limit_per_vendor: all_devices ? nil : sample_size)
devices = backup_plan.inventory
selected = backup_plan.selected
plan = {
  total: devices.size,
  ready: devices.count(&:ready?),
  inventory_issues: devices.reject(&:ready?).group_by(&:issue).transform_values(&:size),
  selected_count: selected.size,
  by_vendor: selected.group_by(&:vendor).transform_values(&:size),
  palo_alto_filename_collisions: backup_plan.outcomes.count { |outcome| outcome&.status == :remote_filename_collision },
  selected: selected.map do |device|
    { host: device.host, name: device.name, vendor: device.vendor,
      remote_path: device.tftp_filename }
  end
}
preview = all_devices ? plan.reject { |key, _value| key == :selected } : plan
puts JSON.generate(plan: preview, server: server, concurrency: settings.concurrency)
$stdout.flush
abort "备份已取消" if ARGV == ["--stdin-credentials"] && STDIN.gets&.strip != "RUN"

File.write(File.join(directory, "plan.json"), JSON.pretty_generate(plan), mode: "w", perm: 0o600)
source_files = settings.tftp_source_files
vrfs = settings.tftp_vrfs
print_lock = Mutex.new
processed = 0
batch = File.open(File.join(directory, "events.jsonl"), "a", 0o600) do |events|
  fleet.tftp_backup_all(server: server, source_files: source_files, plan: backup_plan,
                        report_directory: directory,
                        vrfs: vrfs,
                        concurrency: settings.concurrency,
                        on_result: ->(outcome) {
                          print_lock.synchronize do
                            event = { host: outcome.device.host, vendor: outcome.device.vendor,
                                      status: outcome.status, error_code: outcome.error_code,
                                      error_type: outcome.error_type }
                            events.puts(JSON.generate(event))
                            events.flush
                            processed += 1
                            if !all_devices || outcome.status != :reported_uploaded || (processed % 25).zero?
                              puts JSON.generate(event.merge(processed: processed))
                              $stdout.flush
                            end
                          end
                        })
end
summary = batch.summary
summary.delete(:devices)
summary.merge!(server: server, local_tftp_root: local_tftp_root,
               report_location: batch.report_location, report_error: batch.report_error,
               outcomes: batch.outcomes.map do |outcome|
                 # 完成回执中的 nil 表示实际路径未确认，不能改用计划文件名核验服务器文件。
                 remote_path = outcome.backup ? outcome.backup.path : (outcome.device.tftp_filename if outcome.device.host)
                 verified = false
                 bytes = nil
                 sha256 = nil
                 if outcome.backup && remote_path && local_tftp_root
                   candidate = File.join(local_tftp_root, remote_path)
                   verified = File.file?(candidate) && File.size(candidate).positive? && File.mtime(candidate).utc >= batch.started_at
                   bytes = File.size(candidate) if verified
                   sha256 = Digest::SHA256.file(candidate).hexdigest if verified
                 elsif outcome.backup && remote_path && !all_devices
                   output, _error, status = Open3.capture3("curl", "--silent", "--show-error", "--max-time", "10",
                                                           "--output", File::NULL, "--write-out", "%{size_download}",
                                                           "tftp://#{server}/#{remote_path}")
                   bytes = Integer(output, 10) if status.success?
                   verified = !bytes.nil? && bytes.positive?
                 end
                 session_log = if outcome.device.host
                                 File.join(directory, "logs", "#{outcome.device.host.tr(":", "_")}.log")
                               end
                 { host: outcome.device.host, name: outcome.device.name, vendor: outcome.device.vendor,
                   status: outcome.status, remote_path: remote_path,
                   started_at: outcome.started_at&.iso8601, finished_at: outcome.finished_at&.iso8601,
                   duration_ms: outcome.duration_ms,
                   local_file: verified && local_tftp_root ? candidate : nil, bytes: verified ? bytes : nil,
                   sha256: verified ? sha256 : nil,
                   server_file_verified: verified,
                   session_log: session_log,
                   error_code: outcome.error_code, error_type: outcome.error_type }
               end)
File.write(File.join(directory, "summary.json"), JSON.pretty_generate(summary), mode: "w", perm: 0o600)
logs_directory = File.join(directory, "logs")
FileUtils.mkdir_p(logs_directory, mode: 0o700)
summary.fetch(:outcomes).each do |item|
  next unless item[:session_log]

  result = if item.fetch(:status) == :reported_with_error
             "设备报告上传成功，但路径确认或收尾处理出错；请核对服务器文件"
           elsif item.fetch(:server_file_verified)
             "成功：服务器文件已核验"
           elsif item.fetch(:status) == :reported_uploaded
             "设备报告上传成功；服务器文件尚未核验"
           elsif item.fetch(:status) == :missing_credentials
             "未执行：缺少设备登录凭据"
           elsif item.fetch(:status) == :remote_filename_collision
             "未执行：Palo Alto 设备使用相同的远端文件名，继续上传会覆盖其他设备备份"
           elsif item.fetch(:error_code) == :transfer_failed
             "失败：设备报告 TFTP 传输失败"
           elsif item.fetch(:error_code) == :transfer_unconfirmed
             "未完成：设备没有返回上传成功确认"
           elsif item.fetch(:error_code) == :authentication_failed
             "失败：设备拒绝登录"
           elsif item.fetch(:error_code) == :connection_timeout
             "失败：连接设备超时"
           else
             "失败：设备未完成备份，请查看详细交互"
           end
  lines = [
    "备份结果：#{result}",
    "设备：#{(item[:name] || item.fetch(:vendor).to_s).gsub(/[[:cntrl:]]+/, " ")}（#{item.fetch(:host)}）",
    "目标：#{server}/#{item.fetch(:remote_path) || "（实际路径未确认）"}"
  ]
  lines << "文件大小：#{item.fetch(:bytes)} 字节" if item[:bytes]
  lines << "SHA-256：#{item.fetch(:sha256)}" if item[:sha256]
  known_errors = %i[transfer_failed transfer_unconfirmed authentication_failed connection_timeout]
  lines << "原因代码：#{item[:error_code]}" if item[:error_code] && !known_errors.include?(item[:error_code])
  File.open(item.fetch(:session_log), File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW, 0o600) do |file|
    file.chmod(0o600)
    file.write("\n#{lines.join("\n")}\n")
  end
end
verified_count = summary.fetch(:outcomes).count { |outcome| outcome.fetch(:server_file_verified) }
puts JSON.generate(directory: directory, counts: batch.counts, server_files_verified: verified_count,
                   success: batch.success? && verified_count == batch.outcomes.size)
exit(batch.success? && verified_count == batch.outcomes.size ? 0 : 1)
