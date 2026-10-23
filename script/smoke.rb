# frozen_string_literal: true

# 此文件在独立安装目录执行；不得 require_relative 项目源码或测试替身。
# 模拟宿主先加载依赖，避免仅验证连接器优先加载而漏掉版本冲突。
require "json"
require "logger"
require "net/http"
require "openssl"
require "net/connector"
require "net/connector/netdisco"
require "rbconfig"
require "stringio"
require "open3"

raise "Offline entry eagerly loaded TextFSM" if $LOADED_FEATURES.any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) }

spec = Gem.loaded_specs.fetch("net-connector")
spec.runtime_dependencies.each do |dependency|
  loaded = Gem.loaded_specs[dependency.name]
  next unless loaded

  raise "Loaded dependency violates gemspec: #{dependency.name}" unless dependency.matches_spec?(loaded)
end
root = File.realpath(ENV.fetch("GEM_HOME"))
raise "Gem loaded outside isolated install" unless File.realpath(spec.full_gem_path).start_with?("#{root}/")
raise "Bundler leaked into plain installation" if ARGV.first == "plain" && defined?(Bundler)
raise "Development tools leaked into application" unless (Gem.loaded_specs.keys & %w[rake rubocop parallel]).empty?

%w[expect-pty textfsm digest fileutils forwardable ipaddr json logger net-http open3 openssl
   optparse securerandom shellwords stringio tempfile time timeout uri yaml].each do |name|
  raise "Undeclared runtime dependency: #{name}" unless spec.runtime_dependencies.any? { |dependency| dependency.name == name }
end

Net::Connector.vendors.each do |vendor|
  raise "Vendor profile missing" unless Net::Connector.vendor_class(vendor).profile.config_commands.any?
end

# 从已安装 gem 读取新增平台模板，避免源码目录掩盖资源遗漏。
platform_parser = Net::Connector::TextFSM.new
fortinet_rows = platform_parser.call("1 port 'wan1' 5 mac 00:11:22:33:44:55 chassis 00:11:22:33:44:66 port 'Te1/0/1' system 'core'\n",
                                     vendor: :fortinet, command: "diagnose lldp rx neighbor")
raise "FortiOS template missing" unless fortinet_rows.one? && fortinet_rows.first.fetch("LOCAL_INTERFACE") == "wan1"
juniper_rows = platform_parser.call("Local Interface : ge-0/0/0\nPort ID : Ethernet1/1\nSystem name : core\n",
                                    vendor: :juniper, command: "show lldp neighbors detail | no-more")
raise "Junos template missing" unless juniper_rows.one? && juniper_rows.first.fetch("NEIGHBOR_NAME") == "core"
raise "Junos remote backup missing" unless Net::Connector.vendor_class(:juniper).profile.remote_backup_strategy

nxos_rows = platform_parser.call("IP Interface Status for VRF \"management\"(2)\nmgmt0 192.0.2.1 protocol-up/link-up/admin-up\n",
                                 vendor: :cisco_nxos, command: "show ip interface brief vrf management")
raise "NX-OS interface template missing" unless nxos_rows.one? && nxos_rows.first.fetch("VRF") == "management"
nxos_neighbors = platform_parser.call("Device ID:peer\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n",
                                      vendor: :cisco_nxos, command: "show cdp neighbors detail")
raise "NX-OS CDP template missing" unless nxos_neighbors.one?
nxos_interfaces = platform_parser.call("interface Ethernet1/1\n  description uplink\n",
                                       template: "cisco_nxos/show_running_config.textfsm")
raise "NX-OS configuration template missing" unless nxos_interfaces.one?

# 使用真正的 PTY 子进程验证采集及打包模板，不访问网络设备。
class InstalledTransport < Net::Connector::Transports::Pty
  def protocol = :local

  def argv
    child = <<~'RUBY'
      STDOUT.sync = true
      description = "package-smoke"
      puts "router#"
      while (line = STDIN.gets)
        if line.strip == "show running-config"
          puts "interface Ethernet1/1\n description #{description}\n!"
        elsif line.strip == "show status"
          puts "public-package-output"
        elsif line.strip == "show cdp neighbors detail"
          puts "Device ID: peer\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2"
        elsif line.strip.start_with?("description ")
          description = line.strip.delete_prefix("description ")
        elsif line.strip == "copy running-config startup-config"
          puts "Building configuration...\n[OK]"
        elsif line.strip == "copy running-config tftp:"
          puts "1280 bytes copied in 2.1 secs"
        end
        puts "router#"
      end
    RUBY
    [RbConfig.ruby, "--disable-gems", "-e", child]
  end
end

session_log = StringIO.new
configuration = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", command_timeout: 5,
                                                  logger: Logger.new(session_log), log_level: :debug)
transport = InstalledTransport.new(configuration)
device = Net::Connector.build(:cisco_ios, configuration: configuration, transport: transport)
begin
  result = device.running_config
  raise "Installed collection failed" unless result.value!.include?("package-smoke")
  raise "Installed collection metadata missing" unless result.steps.all? { |step| step.command.output_sensitive? }
  raise "Installed command copy lost privacy" unless result.steps.last.command.with_text("show config").output_sensitive?

  rows = device.parse_config(template: "cisco/show_running_config.textfsm")
  raise "Installed TextFSM template failed" unless rows.first.fetch("DESCRIPTION") == "package-smoke"
  raise "Installed collection leaked diagnostic output" if session_log.string.include?("package-smoke")
  receipts = []
  ordinary = device.execute_command("show status", on_receipt: ->(step) { receipts << step })
  raise "Installed ordinary command failed" unless ordinary.success?
  raise "Installed completion callback lost a step" unless receipts == ordinary.steps && receipts.one?
  raise "Installed ordinary logging did not resume" unless session_log.string.include?("public-package-output")

  directory = File.join(root, "backup-smoke-#{ARGV.fetch(0)}")
  Dir.mkdir(directory, 0o700)
  backup = device.backup(path: File.join(directory, "192.0.2.1.txt"))
  raise "Installed backup failed" unless backup.change == :created && File.binread(backup.path).include?("package-smoke")
  raise "Installed backup is not private" unless (File.stat(backup.path).mode & 0o7777) == 0o600
  lock_path = Net::Connector::Storage::BackupLock.lock_path(backup.path)
  raise "Installed path lock is not private" unless (File.stat(lock_path).mode & 0o7777) == 0o600
  receipt = Net::Connector::Storage::AtomicFile.write(File.join(directory, "receipt.txt"), "fixture")
  raise "Installed directory synchronization failed" unless receipt.durable?
  saved = Net::Connector::Storage::SavedConfig.new(directory: directory)
  raise "Installed safe read failed" unless saved.read("192.0.2.1") == File.binread(backup.path)
  begin
    Net::Connector::TextFSM.new.call("\xFF".b, template: "cisco/show_running_config.textfsm")
    raise "Installed parser accepted invalid encoding"
  rescue Net::Connector::ParsingError => error
    raise "Installed encoding error changed" unless error.code == :invalid_output_encoding && error.cause.nil?
  end

  applied = device.interfaces.sync
  raise "Installed staged topology failed" unless applied.success?
  raise "Installed description format changed" unless device.interfaces.descriptions.fetch("ethernet1/1") == "To_peer_Eth1/2"
  raise "Installed topology omitted readback steps" unless applied.steps.any? { |step| step.command.text == "show running-config" && step.command.output_sensitive? }

  transfer = device.tftp_backup(host: "192.0.2.10", path: "installed.cfg")
  raise "Installed TFTP metadata failed" unless transfer.configuration_kind == :running && transfer.format == :cfg
  raise "Installed TFTP evidence level changed" unless transfer.verification == :device_reported && transfer.server_sha256.nil?
  raise "Installed TFTP target changed" unless transfer.path == "installed.cfg" && transfer.requested_path == "installed.cfg"
ensure
  device.close
end

budget_configuration = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", command_timeout: 5,
                                                         max_script_output_bytes: 32)
budget_transport = InstalledTransport.new(budget_configuration)
budget_device = Net::Connector.build(:cisco_ios, configuration: budget_configuration, transport: budget_transport)
begin
  receipts = []
  bounded = budget_device.execute_script(["show status", "show status", "never"], on_receipt: ->(step) { receipts << step })
  raise "Installed script budget did not stop the script" unless bounded.error.instance_of?(Net::Connector::ScriptOutputLimitExceeded)
  raise "Installed script budget lost finished output" unless bounded.steps.size == 2 && bounded.steps.all? { |step| step.output.include?("public-package-output") }
  raise "Installed receipt callback lost budget failure evidence" unless receipts == bounded.steps
  raise "Installed script budget left transport open" unless budget_transport.closed?
ensure
  budget_device.close
end

output = StringIO.new
cli = Net::Connector::Netdisco::CLI.new(argv: ["--version"], env: {}, output: output)
raise "Installed CLI failed" unless cli.run.zero? && output.string.strip == spec.version.to_s

# 实际运行 RubyGems 生成的入口，覆盖打包路径、执行位和安装后的参数/退出码。
raise "Installed executable metadata differs" unless spec.bindir == "bin" && spec.executables == ["net-backup"]
executable = File.join(Gem.bindir, "net-backup")
source_executable = File.join(spec.full_gem_path, "bin", "net-backup")
raise "Installed executable is missing or not executable" unless File.executable?(executable) && File.executable?(source_executable)
raise "Executable wrapper escaped isolated install" unless File.realpath(executable).start_with?("#{root}/")
{
  "--version" => [0, spec.version.to_s],
  "--help" => [0, "Usage: net-backup"],
  "--invalid-fixture-option" => [2, "net-backup: invalid arguments"]
}.each do |argument, (exit_status, expected)|
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, argument)
  raise "Installed executable exit status differs for #{argument}" unless status.exitstatus == exit_status
  actual, other = exit_status.zero? ? [stdout, stderr] : [stderr, stdout]
  raise "Installed executable output differs for #{argument}" unless actual.include?(expected) && other.empty?
end

settings = Net::Connector::Netdisco::Settings.new(env: {}, defaults: { "ND_MAX_DEVICES" => "2" })
policy = settings.snapshot(mode: :show_config)
raise "Installed inventory budget missing" unless policy.inventory_options.fetch(:max_devices) == 2 && policy.frozen?
output = StringIO.new
cli = Net::Connector::Netdisco::CLI.new(argv: ["--show-config", "--max-script-output-bytes", "64"], env: {}, output: output)
raise "Installed offline settings failed" unless cli.run.zero? && JSON.parse(output.string).fetch("netdisco").fetch("inventory_timeout") == 300
raise "Installed script budget setting missing" unless JSON.parse(output.string).fetch("ssh").fetch("max_script_output_bytes") == 64

# 安装包独立提供数据库驱动与配置示例；这里只做离线校验，真实查询由 test:postgres 验证。
require "pg"
database_example = File.join(spec.full_gem_path, "examples/inventory.yml")
database_settings = Net::Connector::Netdisco::Settings.from_file(database_example, env: {})
raise "Installed PostgreSQL settings missing" unless database_settings.inventory_source == :postgres
raise "Installed PostgreSQL query missing" unless database_settings.inventory_options.fetch(:query).include?("$1")
raise "Installed PostgreSQL driver unavailable" unless PG.library_version.positive?

# 不连接设备即可检查安装包中的统一报告和成功策略。
inventory_device = Net::Connector::Netdisco::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "Cisco" },
                                                             rules: Net::Connector::Netdisco::Rules.new)
outcomes = %i[backed_up filtered].map do |status|
  Net::Connector::Netdisco::Outcome.new(device: inventory_device, status: status, backup: nil, error_code: nil, error_type: nil)
end
batch = Net::Connector::Netdisco::Batch.new(mode: :backup, outcomes: outcomes, started_at: Time.now.utc,
                                            finished_at: Time.now.utc, callback_errors: [], report_error: nil, report_location: nil)
report = batch.build_report(policy: :selected)
raise "Installed selected policy failed" unless report.policy_success? && !report.success? && report.status == :incomplete
raise "Installed v2 coverage missing" unless report.summary.fetch(:schema_version) == 2 && !report.summary.fetch(:coverage).fetch(:complete)
options = Net::Connector::Netdisco::CLI::Options.parse(argv: ["--parallel", "2", "--refresh-inventory"])
raise "Installed backup options missing" unless options.fetch(:environment).fetch("NC_PARALLEL") == "2"
raise "Installed inventory refresh option missing" unless options.fetch(:force_refresh)

# 安装后的公共并发、配置编排和清单缓存走真实入口，设备仍使用本地 PTY。
pool = Net::Connector::Parallel::Pool.new(parallel: 2)
raise "Installed execution pool lost ordering" unless pool.map([2, 1]) { |item| item * 2 } == [4, 2]
settings = Net::Connector::Netdisco::Settings.new(env: { "NC_PARALLEL" => "2", "ND_CACHE_TTL" => "3600" })
raise "Installed parallel environment missing" unless settings.snapshot.parallel == 2
raise "Installed cache environment missing" unless settings.snapshot.inventory_cache_options.fetch(:ttl) == 3600
Dir.mktmpdir do |cache_directory|
  calls = 0
  inventory = Object.new
  inventory.define_singleton_method(:devices) do
    calls += 1
    [{ "ip" => "192.0.2.1", "vendor" => "Cisco", "os" => "ios" }]
  end
  cache = Net::Connector::Netdisco::Inventory::Cache.new(inventory: inventory, directory: cache_directory, identity: "installed")
  rows = cache.devices
  raise "Installed inventory cache lost rows" unless rows == cache.devices && calls == 1
  cache.devices(force_refresh: true)
  raise "Installed forced refresh missing" unless calls == 2 && cache.status == :refreshed
  fleet = Net::Connector::Netdisco::Fleet.new(inventory: cache, settings: settings,
    credentials: ->(_) { { username: "audit" } }, connector_factory: lambda { |_, _|
      config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", command_timeout: 5)
      Net::Connector.build(:cisco_ios, configuration: config, transport: InstalledTransport.new(config))
    })
  batch = fleet.execute_scripts(scripts: { "192.0.2.1" => ["show status"] }, confirmed: true)
  raise "Installed configuration batch failed" unless batch.success? && batch.outcomes.first.value.steps.size == 1
  raise "Installed configuration report missing" unless batch.to_h.fetch(:summary).values_at(:total, :succeeded, :failed) == [1, 1, 0]
end
Dir.mktmpdir do |root|
  directory = Net::Connector::Storage::BatchDirectory.create(root, time: Time.utc(2026, 1, 1))
  raise "Installed batch files missing" unless File.basename(directory) == "2026-01-01_08-00-00"
end
help = StringIO.new
raise "Installed batch runner missing" unless Net::Connector::Netdisco::CLI::Backup.new(mode: :tftp, argv: ["--help-all"], output: help).run.zero?
raise "Installed verification option missing" unless help.string.include?("verified")
topology_help = StringIO.new
raise "Installed topology entry missing" unless Net::Connector::Netdisco::CLI::Topology.new(argv: ["--help"], output: topology_help).run.zero?
raise "Installed topology apply option missing" unless topology_help.string.include?("--apply")
raise "Installed report writer missing" unless Net::Connector::Netdisco::Report::Files.respond_to?(:write)
raise "Installed backup connection missing" unless Net::Connector::Netdisco::CLI::Credentials.respond_to?(:resolve)
puts "Installed #{spec.full_name}: #{ARGV.fetch(0)}, PTY, vendor profiles, templates and CLI passed"
