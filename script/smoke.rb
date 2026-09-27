# frozen_string_literal: true

# 此文件在独立安装目录执行；不得 require_relative 项目源码或测试替身。
require "net/connector"
require "net/connector/netdisco"
require "rbconfig"
require "stringio"
require "logger"

raise "Offline entry eagerly loaded TextFSM" if $LOADED_FEATURES.any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) }

spec = Gem.loaded_specs.fetch("net-connector")
root = File.realpath(ENV.fetch("GEM_HOME"))
raise "Gem loaded outside isolated install" unless File.realpath(spec.full_gem_path).start_with?("#{root}/")
raise "Bundler leaked into plain installation" if ARGV.first == "plain" && defined?(Bundler)
raise "Development tools leaked into application" unless (Gem.loaded_specs.keys & %w[rake rubocop parallel]).empty?

%w[expect-pty textfsm digest english fileutils forwardable ipaddr json logger net-http open3 openssl
   optparse securerandom shellwords stringio tempfile time timeout uri yaml].each do |name|
  raise "Undeclared runtime dependency: #{name}" unless spec.runtime_dependencies.any? { |dependency| dependency.name == name }
end

Net::Connector.vendors.each do |vendor|
  raise "Vendor profile missing" unless Net::Connector.vendor_class(vendor).profile.config_commands.any?
end

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

  rows = device.parse_config(template: "cisco_ios_running_config_interfaces.textfsm")
  raise "Installed TextFSM template failed" unless rows.first.fetch("DESCRIPTION") == "package-smoke"
  raise "Installed collection leaked diagnostic output" if session_log.string.include?("package-smoke")
  raise "Installed ordinary command failed" unless device.execute_command("show status").success?
  raise "Installed ordinary logging did not resume" unless session_log.string.include?("public-package-output")

  directory = File.join(root, "backup-smoke-#{ARGV.fetch(0)}")
  Dir.mkdir(directory, 0o700)
  backup = device.backup(path: File.join(directory, "192.0.2.1.txt"))
  raise "Installed backup failed" unless backup.change == :created && File.binread(backup.path).include?("package-smoke")
  raise "Installed backup is not private" unless (File.stat(backup.path).mode & 0o7777) == 0o600
  lock_path = Net::Connector::Storage::BackupLock.lock_path(backup.path)
  raise "Installed path lock is not private" unless (File.stat(lock_path).mode & 0o7777) == 0o600
  receipt = Net::Connector::Storage::PrivateFile.write(File.join(directory, "receipt.txt"), "fixture")
  raise "Installed directory synchronization failed" unless receipt.durable?
  saved = Net::Connector::Storage::SavedConfig.new(directory: directory)
  raise "Installed safe read failed" unless saved.read("192.0.2.1") == File.binread(backup.path)
  begin
    Net::Connector::TextFSM.new.call("\xFF".b, template: "cisco_ios_running_config_interfaces.textfsm")
    raise "Installed parser accepted invalid encoding"
  rescue Net::Connector::ParsingError => error
    raise "Installed encoding error changed" unless error.code == :invalid_output_encoding && error.cause.nil?
  end

  plan = device.plan_interface_descriptions { "installed topology" }
  raise "Installed plan omitted verification" unless plan.commands.last(3) == ["terminal length 0", "show running-config", "copy running-config startup-config"]
  applied = device.apply_interface_descriptions(plan, confirmed: true)
  raise "Installed staged topology failed" unless applied.success?
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
  bounded = budget_device.execute_script(["show status", "show status", "never"])
  raise "Installed script budget did not stop the script" unless bounded.error.instance_of?(Net::Connector::ScriptOutputLimitExceeded)
  raise "Installed script budget lost finished output" unless bounded.steps.size == 2 && bounded.steps.all? { |step| step.output.include?("public-package-output") }
  raise "Installed script budget left transport open" unless budget_transport.closed?
ensure
  budget_device.close
end

output = StringIO.new
cli = Net::Connector::Netdisco::CLI.new(argv: ["--version"], env: {}, output: output)
raise "Installed CLI failed" unless cli.run.zero? && output.string.strip == spec.version.to_s
settings = Net::Connector::Netdisco::Settings.new(env: { "NETDISCO_MAX_DEVICES" => "2" })
policy = settings.snapshot(mode: :show_config)
raise "Installed inventory budget missing" unless policy.client_options.fetch(:max_devices) == 2 && policy.frozen?
output = StringIO.new
cli = Net::Connector::Netdisco::CLI.new(argv: ["--show-config", "--max-script-output-bytes", "64"], env: {}, output: output)
raise "Installed offline settings failed" unless cli.run.zero? && JSON.parse(output.string).fetch("netdisco").fetch("inventory_timeout") == 300
raise "Installed script budget setting missing" unless JSON.parse(output.string).fetch("ssh").fetch("max_script_output_bytes") == 64

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
puts "Installed #{spec.full_name}: #{ARGV.fetch(0)}, PTY, vendor profiles, templates and CLI passed"
