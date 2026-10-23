# frozen_string_literal: true

require "json"
require "ipaddr"
require "optparse"
require_relative "../version"
require_relative "fleet"
require_relative "cli/options"
require_relative "cli/setup"

module Net
  module Connector
    module Netdisco
      class CLI
        # 保存命令行输入输出和清单任务工厂。
        def initialize(argv: ARGV, env: ENV, input: $stdin, output: $stdout, error: $stderr,
                       fleet_factory: ->(settings) { Fleet.new(settings: settings) }, configuration_options: {})
          @argv = argv.dup
          @env = env
          @input = input
          @output = output
          @error = error
          @fleet_factory = fleet_factory
          @configuration_options = configuration_options
        end

        # 解析参数并执行预览、导出或批量备份。
        def run
          options = parse_options
          return 0 if options[:done]

          validate_options!(options)
          return 0 if initialize_config?(options)
          settings = settings_for(options)

          return show_config(settings, options) if options[:show_config]
          if options[:export]
            export_config(settings, options)
            return 0
          end
          if options[:tftp] && !options[:plan] && !settings.tftp_server
            raise ArgumentError, "YAML tftp.server is required"
          end

          fleet = @fleet_factory.call(settings)
          plan = backup_plan(fleet, settings, options)
          inventory_warning(fleet)
          if options[:plan]
            @output.puts JSON.pretty_generate(plan_summary(plan))
            return 0
          end

          report = backup(fleet, plan, settings, options)
          summary = report.summary
          @output.puts JSON.pretty_generate(summary)
          report.policy_success? ? 0 : 1
        rescue Storage::AtomicFile::WriteError => exception
          message = Storage::AtomicFile.receipt_error?(exception) ? exception.message : exception.class.name
          @error.puts "net-backup: #{message}"
          2
        rescue OptionParser::ParseError
          @error.puts "net-backup: invalid arguments; use --help for options"
          2
        rescue ArgumentError, KeyError, Errno::ENOENT,
          Psych::Exception, JSON::ParserError, Inventory::Error => exception
          @error.puts "net-backup: #{exception.message}"
          2
        rescue StandardError => exception
          @error.puts "net-backup failed (#{exception.class})"
          2
        end

        private

        # 非敏感设置与来源在创建清单之前输出。
        def show_config(settings, options)
          @output.puts JSON.pretty_generate(settings.public_config.merge(sources: Options.sources(@configuration, options)))
          0
        end

        # 初始化仅发布用户配置，不读取清单或进入设备执行。
        def initialize_config?(options)
          @configuration = Options.configuration(options, env: @env, **@configuration_options)
          return false unless options[:init] || options[:interactive]

          mode = options[:tftp] ? :tftp : :backup
          Setup.new(mode: mode, options: options, input: @input, output: @error,
                    configuration: @configuration, directory: File.expand_path("backups")).initialize_files?
        end

        # CLI 覆盖支持的环境变量与 YAML；设备凭据按环境或显式 CLI 参数解析。
        def settings_for(options)
          mode = options[:export] ? :export : (options[:tftp] ? :tftp : :backup)
          Options.settings(options, env: @env, configuration: @configuration).for_run(mode: mode)
        end

        # 导出已有配置不创建清单或设备连接。
        def export_config(settings, options)
          path = Storage::SavedConfig.new(directory: settings.backup_directory)
                                     .export(host: options[:export], output: options[:output], io: @output)
          @output.puts JSON.generate(host: options[:export], output: path) if path
        end

        # 预览与执行共用计划和主机存在性检查。
        def backup_plan(fleet, settings, options)
          limit = options[:all] ? nil : options[:limit] || settings.limit_per_vendor(tftp: options[:tftp])
          refresh = options[:force_refresh] ? { force_refresh: true } : {}
          plan = if options[:tftp]
                   fleet.plan_tftp_backup(limit_per_vendor: limit, **refresh)
                 else
                   fleet.plan_backup(limit_per_vendor: limit, **refresh)
                 end
          options[:host]&.split(",")&.each do |host|
            raise ArgumentError, "Device not found in inventory: #{host}" unless plan.inventory.any? { |device| device.host == host }
          end
          plan
        end

        # 回退历史只描述清单来源，不把缓存命中误报为远端已恢复。
        def inventory_warning(fleet)
          status = fleet.inventory_status if fleet.respond_to?(:inventory_status)
          if status && status[:source] == :stale_cache
            @error.puts "net-backup: inventory refresh failed; using the previous cache (#{status[:refresh_error_code]})"
          end
          @error.puts "net-backup: inventory cache write failed (#{status[:write_error_type]})" if status && status[:write_error_type]
        end

        # 仅执行已经校验的计划，保留本地与 TFTP 两种结果语义。
        def backup(fleet, plan, settings, options)
          reporting = options.slice(:success_policy)
          if options[:tftp]
            fleet.tftp_backup_all(plan: plan, server: settings.tftp_server,
                                  parallel: settings.parallel,
                                  vrfs: settings.tftp_vrfs,
                                  source_files: settings.tftp_source_files, verification_root: options[:tftp_root] || settings.tftp_root, **reporting)
          else
            fleet.backup_all(plan: plan, directory: settings.backup_directory,
                             parallel: settings.parallel, **reporting)
          end
        end

        # 解析命令行参数并处理帮助及版本信息。
        def parse_options
          options = { environment: {} }
          parser = OptionParser.new do |args|
            args.banner = "Usage: net-backup [--config FILE] [--plan | --show-config | --export IP] [--tftp]"
            Options.add_settings(args, options)
            Options.add_execution(args, options)
            args.on("--init", "Create missing configuration and environment templates in the user directory, then exit") { options[:init] = true }
            args.on("--interactive", "Create missing configuration through terminal prompts") { options[:interactive] = true }
            args.on("--non-interactive", "Disable configuration prompts") { options[:interactive] = false }
            args.on("--source SOURCE", %w[http postgres], "Inventory source: http (default) or postgres") { |value| options[:source] = value }
            args.on("--query SQL", "PostgreSQL inventory query using $1 and $2 bound parameters") { |value| options[:query] = value }
            args.on("--query-params JSON", "JSON array of query parameters") { |value| options[:query_params] = value }
            args.on("--plan", "Preview device inventory without connecting to devices") { options[:plan] = true }
            args.on("--tftp", "Have devices initiate TFTP backups") { options[:tftp] = true }
            args.on("--export IP", "Export a saved local configuration") { |value| options[:export] = value }
            args.on("--output FILE", "Write exported configuration to a private file") { |value| options[:output] = value }
            args.on("--max-script-output-bytes N", Integer, "Cumulative response byte limit per script") { |value| options[:max_script_output_bytes] = value }
            args.on("-v", "--version", "Show version") do
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
          raise ArgumentError, "verified policy requires --tftp" if options[:success_policy] == :verified && !options[:tftp]
          Report.validate_policy!(options.fetch(:success_policy, :strict))
          Planner.validate_limit!(options[:limit])
          raise ArgumentError, "--tftp-root requires --tftp" if options[:tftp_root] && !options[:tftp]
          modes = [:show_config, :plan, :export].count { |key| options[key] }
          raise ArgumentError, "Select only one of --show-config, --plan and --export" if modes > 1
          raise ArgumentError, "--output requires --export" if options[:output] && !options[:export]
          raise ArgumentError, "--all cannot be combined with --limit-per-vendor" if options[:all] && options[:limit]
          if options[:export] && (options[:source] || options[:query] || options[:query_params])
            raise ArgumentError, "--export cannot be combined with inventory query options"
          end
          if options[:export] && (options[:tftp] || options[:all] || options[:limit] || options[:environment].key?("NC_PARALLEL") || options[:host] ||
            options[:success_policy] || options[:tftp_root] || options[:max_script_output_bytes] || options[:force_refresh])
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
