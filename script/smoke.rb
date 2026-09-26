# frozen_string_literal: true

# 此文件在独立安装目录执行；不得 require_relative 项目源码或测试替身。
require "net/connector"
require "net/connector/netdisco"
require "rbconfig"
require "stringio"

spec = Gem.loaded_specs.fetch("net-connector")
root = File.realpath(ENV.fetch("GEM_HOME"))
raise "Gem loaded outside isolated install" unless File.realpath(spec.full_gem_path).start_with?("#{root}/")
raise "Bundler leaked into plain installation" if ARGV.first == "plain" && defined?(Bundler)
raise "Development tools leaked into application" unless (Gem.loaded_specs.keys & %w[rake rubocop parallel]).empty?

%w[expect-pty textfsm digest english fileutils forwardable ipaddr json logger net-http open3 openssl
   optparse securerandom shellwords stringio tempfile time uri yaml].each do |name|
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
      puts "router#"
      while (line = STDIN.gets)
        if line.strip == "show running-config"
          puts "interface Ethernet1/1\n description package-smoke\n!"
        end
        puts "router#"
      end
    RUBY
    [RbConfig.ruby, "--disable-gems", "-e", child]
  end
end

configuration = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", command_timeout: 5)
transport = InstalledTransport.new(configuration)
device = Net::Connector.build(:cisco_ios, configuration: configuration, transport: transport)
begin
  result = device.running_config
  raise "Installed collection failed" unless result.value!.include?("package-smoke")

  rows = device.parse_config(template: "cisco_ios_running_config_interfaces.textfsm")
  raise "Installed TextFSM template failed" unless rows.first.fetch("DESCRIPTION") == "package-smoke"
ensure
  device.close
end

output = StringIO.new
cli = Net::Connector::Netdisco::CLI.new(argv: ["--version"], env: {}, output: output)
raise "Installed CLI failed" unless cli.run.zero? && output.string.strip == spec.version.to_s
puts "Installed #{spec.full_name}: #{ARGV.fetch(0)}, PTY, vendor profiles, templates and CLI passed"
