# frozen_string_literal: true

require "json"
require "ipaddr"
require "optparse"

module Net
  module Connector
    module Netdisco
      class CLI
        # 保存命令行输入输出和清单任务工厂。
        def initialize(argv: ARGV, env: ENV, output: $stdout, error: $stderr,
                       fleet_factory: ->(settings) { Fleet.new(settings: settings) })
          @argv = argv.dup
          @env = env
          @output = output
          @error = error
          @fleet_factory = fleet_factory
        end

        # 解析参数并执行预览、导出或批量备份。
        def run
          options = parse_options
          return 0 if options[:done]

          validate_options!(options)
          values = options[:config] ? ConfigFile.load(options[:config]).merge(@env.to_h) : @env.to_h
          values["NET_CONNECTOR_BACKUP_DIRECTORY"] = options[:directory] if options[:directory]
          values["NET_CONNECTOR_CONCURRENCY"] = options[:concurrency].to_s if options[:concurrency]
          values["NET_CONNECTOR_INCLUDE_HOSTS"] = options[:host] if options[:host]
          settings = Settings.new(env: values)

          if options[:show_config]
            @output.puts JSON.pretty_generate(settings.public_config)
            return 0
          end
          if options[:export]
            path = Operations::SavedConfig.new(directory: settings.backup_directory)
                                          .export(host: options[:export], output: options[:output], io: @output)
            @output.puts JSON.generate(host: options[:export], output: path) if path
            return 0
          end

          fleet = @fleet_factory.call(settings)
          limit = options[:all] ? nil : options[:limit] || settings.limit_per_vendor(tftp: options[:tftp])
          plan = if options[:tftp]
                   fleet.plan_tftp_backup(limit_per_vendor: limit)
                 else
                   fleet.plan_backup(limit_per_vendor: limit)
                 end
          if options[:host]
            host = IPAddr.new(options[:host]).to_s
            raise ArgumentError, "host #{options[:host]} was not found in inventory" unless plan.inventory.any? { |device| device.host == host }
          end
          if options[:plan]
            @output.puts JSON.pretty_generate(plan_summary(plan))
            return 0
          end

          batch = if options[:tftp]
                    fleet.tftp_backup_all(plan: plan, server: values.fetch("TFTP_HOST"),
                                          concurrency: settings.concurrency,
                                          vrfs: settings.tftp_vrfs,
                                          source_files: settings.tftp_source_files)
                  else
                    fleet.backup_all(plan: plan, directory: settings.backup_directory,
                                     concurrency: settings.concurrency)
                  end
          @output.puts JSON.pretty_generate(batch.summary.merge(report_location: batch.report_location,
                                                                report_error: batch.report_error))
          batch.success? ? 0 : 1
        rescue OptionParser::ParseError, ArgumentError, KeyError, Errno::ENOENT,
          Psych::Exception, JSON::ParserError, Client::Error => exception
          @error.puts "net-connector-backup: #{exception.message}"
          2
        rescue StandardError => exception
          @error.puts "net-connector-backup failed (#{exception.class})"
          2
        end

        private

        # 解析命令行参数并处理帮助及版本信息。
        def parse_options
          options = { config: @env["NET_CONNECTOR_CONFIG"] }
          parser = OptionParser.new do |args|
            args.banner = "Usage: net-connector-backup [--config FILE] [--plan | --show-config | --export IP] [--tftp]"
            args.on("--config FILE", "Read non-secret YAML settings") { |value| options[:config] = value }
            args.on("--show-config", "Print effective non-secret settings") { options[:show_config] = true }
            args.on("--plan", "Preview selected inventory without device connections") { options[:plan] = true }
            args.on("--tftp", "Use device-initiated TFTP backup") { options[:tftp] = true }
            args.on("--export IP", "Export a saved local configuration") { |value| options[:export] = value }
            args.on("--output FILE", "Write exported configuration to a private file") { |value| options[:output] = value }
            args.on("--directory PATH", "Backup and report directory") { |value| options[:directory] = value }
            args.on("--host IP", "Select one inventory device by management IP") { |value| options[:host] = value }
            args.on("--concurrency N", Integer, "Maximum simultaneous devices") { |value| options[:concurrency] = value }
            args.on("--limit-per-vendor N", Integer, "Select N devices per vendor (1..5)") do |value|
              options[:limit] = value
            end
            args.on("--all", "Select all ready devices") { options[:all] = true }
            args.on("-v", "--version", "Print version") do
              @output.puts Net::Connector::VERSION
              options[:done] = true
            end
            args.on("-h", "--help", "Show help") do
              @output.puts args
              options[:done] = true
            end
          end
          parser.parse!(@argv)
          raise OptionParser::InvalidOption, @argv.join(" ") unless @argv.empty?

          options
        end

        # 拒绝互斥或缺少依赖的命令行选项。
        def validate_options!(options)
          modes = [:show_config, :plan, :export].count { |key| options[key] }
          raise ArgumentError, "choose one of --show-config, --plan, or --export" if modes > 1
          raise ArgumentError, "--output requires --export" if options[:output] && !options[:export]
          raise ArgumentError, "--all and --limit-per-vendor cannot be combined" if options[:all] && options[:limit]
          if options[:export] && (options[:tftp] || options[:all] || options[:limit] || options[:concurrency] || options[:host])
            raise ArgumentError, "--export cannot be combined with backup options"
          end
        end

        # 整理备份计划供命令行预览。
        def plan_summary(plan)
          {
            total: plan.inventory.size,
            ready: plan.inventory.count(&:ready?),
            selected: plan.selected.map do |device|
              { host: device.host, name: device.name, connector: device.vendor,
                filename: plan.mode == :backup ? device.backup_filename : device.tftp_filename }
            end,
            skipped: plan.outcomes.compact.group_by(&:status).transform_values(&:size)
          }
        end
      end
    end
  end
end
