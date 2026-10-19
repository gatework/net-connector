# frozen_string_literal: true

require "json"
require "ipaddr"
require "optparse"
require_relative "../version"
require_relative "fleet"
require_relative "cli/options"

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
          settings = settings_for(options)

          if options[:show_config]
            @output.puts JSON.pretty_generate(settings.public_config)
            return 0
          end
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
          @error.puts "net-backup: 参数无效；使用 --help 查看参数"
          2
        rescue ArgumentError, KeyError, Errno::ENOENT,
          Psych::Exception, JSON::ParserError, Inventory::Error => exception
          @error.puts "net-backup: #{exception.message}"
          2
        rescue StandardError => exception
          @error.puts "net-backup 失败（#{exception.class}）"
          2
        end

        private

        # CLI 覆盖支持的环境变量与 YAML；设备凭据按环境或显式 CLI 参数解析。
        def settings_for(options)
          mode = options[:export] ? :export : (options[:tftp] ? :tftp : :backup)
          Options.settings(options, env: @env).for_run(mode: mode)
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
            raise ArgumentError, "清单中未找到设备 #{host}" unless plan.inventory.any? { |device| device.host == host }
          end
          plan
        end

        # 回退历史只描述清单来源，不把缓存命中误报为远端已恢复。
        def inventory_warning(fleet)
          status = fleet.inventory_status if fleet.respond_to?(:inventory_status)
          if status && status[:source] == :stale_cache
            @error.puts "net-backup: 清单刷新失败，使用历史缓存（#{status[:refresh_error_code]}）"
          end
          @error.puts "net-backup: 清单缓存写入失败（#{status[:write_error_type]}）" if status && status[:write_error_type]
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
            args.banner = "用法：net-backup [--config FILE] [--plan | --show-config | --export IP] [--tftp]"
            Options.add_settings(args, options)
            Options.add_execution(args, options)
            args.on("--source SOURCE", %w[http postgres], "清单来源：http（默认）或 postgres") { |value| options[:source] = value }
            args.on("--query SQL", "PostgreSQL 清单查询，使用 $1、$2 绑定参数") { |value| options[:query] = value }
            args.on("--query-params JSON", "查询参数的 JSON 数组") { |value| options[:query_params] = value }
            args.on("--show-config", "显示生效的非敏感设置") { options[:show_config] = true }
            args.on("--plan", "预览设备清单，不连接设备") { options[:plan] = true }
            args.on("--tftp", "由设备发起 TFTP 备份") { options[:tftp] = true }
            args.on("--export IP", "导出已保存的本地配置") { |value| options[:export] = value }
            args.on("--output FILE", "将导出配置写入私有文件") { |value| options[:output] = value }
            args.on("--max-script-output-bytes N", Integer, "每个脚本的累计响应字节上限") { |value| options[:max_script_output_bytes] = value }
            args.on("-v", "--version", "显示版本") do
              @output.puts Net::Connector::VERSION
              options[:done] = true
            end
            args.on("-h", "--help", "显示帮助") do
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
          raise ArgumentError, "--show-config、--plan 和 --export 只能选择一项" if modes > 1
          raise ArgumentError, "--output 需要同时指定 --export" if options[:output] && !options[:export]
          raise ArgumentError, "--all 不能与 --limit-per-vendor 同时使用" if options[:all] && options[:limit]
          if options[:export] && (options[:source] || options[:query] || options[:query_params])
            raise ArgumentError, "--export 不能与清单查询选项同时使用"
          end
          if options[:export] && (options[:tftp] || options[:all] || options[:limit] || options[:environment].key?("NC_PARALLEL") || options[:host] ||
            options[:success_policy] || options[:tftp_root] || options[:max_script_output_bytes] || options[:force_refresh])
            raise ArgumentError, "--export 不能与备份选项同时使用"
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
