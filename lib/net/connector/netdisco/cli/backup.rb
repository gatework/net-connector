# frozen_string_literal: true

require "json"
require "socket"
require_relative "options"
require_relative "credentials"
require_relative "../fleet"
require_relative "setup"
require_relative "../progress"
require_relative "../report/files"
require_relative "../../storage/batch_directory"

module Net
  module Connector
    module Netdisco
      class CLI
        # 终端备份入口：固定配置、预览、执行、保存报告，最后决定输出与退出码。
        class Backup
          # 保存批次模式与调用方 IO，构造阶段不读取清单、不创建目录。
          def initialize(mode: :backup, argv: ARGV, env: ENV, input: $stdin, output: $stdout, error: $stderr,
                         default_config: nil, default_directory: nil, default_env: nil, load_env: false)
            raise ArgumentError, "mode must be backup or tftp" unless %i[backup tftp].include?(mode)

            @mode, @argv, @env, @input, @output, @error = mode, argv, env, input, output, error
            @default_config, @default_directory = default_config, default_directory
            @load_env, @default_env = load_env, default_env
          end

          # 先固定并校验策略，再预览、执行和保存报告；成功判定使用最终报告。
          def run
            options = CLI::Options.parse(argv: @argv, input: @input, output: @output, error: @error, mode: @mode)
            return 0 if options[:help]
            apply_defaults(options)
            return 0 if initialize_config?(options)

            settings, success_policy, server_root, batch_directory = prepare(options)
            inventory, credentials = Credentials.resolve(settings, stdin_credentials: options[:stdin_credentials], input: @input)
            progress = Progress.new(io: @error, enabled: !options[:no_progress], verbose: options[:verbose])
            resolver = ->(device) { credentials.call(device)&.merge(on_event: progress.method(:event)) }
            fleet = Fleet.new(inventory: inventory, settings: settings, credentials: resolver, report_store: nil)
            plan = read_plan(fleet, settings, options, progress, server_root)
            return preview_status(plan, options) if options[:plan] || options[:inventory_only]
            return 1 if options[:stdin_credentials] && @input.gets("\n")&.strip != "RUN"

            Storage::AtomicFile.write(File.join(batch_directory, "plan.json"), JSON.pretty_generate(plan_summary(plan)))
            report = execute(fleet, settings, plan, batch_directory, progress, success_policy, server_root)
            report = record_progress_error(report, progress)
            report = Report::Files.write(report, directory: batch_directory, plan: plan, parallel: settings.parallel)
            finish(report, progress, options, batch_directory, plan, settings.parallel)
          rescue Interrupt
            finish_interrupted(fleet, progress, options, batch_directory, plan, settings)
            130
          rescue EOFError
            @error.puts "配置输入未完成，已停止；请检查先前提示的文件。"
            2
          rescue ArgumentError, Inventory::Error => exception
            @error.puts "备份参数或清单错误：#{exception.message}"
            2
          rescue StandardError => exception
            @error.puts "备份未完成（#{exception.class}）"
            2
          end

          private

          # 按固定策略读取一次清单并生成计划，同时展示缓存诊断与执行规模。
          def read_plan(fleet, settings, options, progress, server_root)
            progress.reading_inventory(config: options.fetch(:environment)["NC_CONFIG"] || @env["NC_CONFIG"])
            limit = settings.limit_per_vendor
            refresh = options[:force_refresh] ? { force_refresh: true } : {}
            plan = if @mode == :backup || options[:inventory_only]
                     fleet.plan_backup(limit_per_vendor: limit, **refresh)
                   else
                     fleet.plan_tftp_backup(limit_per_vendor: limit,
                                            allow_fixed_name_reuse: !server_root.nil? || !settings.tftp_verification_roots.empty?, **refresh)
                   end
            inventory_warning(fleet)
            progress.plan(plan, parallel: settings.parallel, limit_per_vendor: limit)
            preview = plan_summary(plan)
            @output.puts JSON.generate(plan: preview) if options[:json]
            @output.flush
            plan
          end

          # 输出已选择设备的安全预览，根据空选择或异常跳过项决定退出码。
          def preview_status(plan, options)
            @output.puts(plan.selected.map { |device| "#{device.host}\t#{device.name.to_s.gsub(/[[:cntrl:]]/, " ")}\t#{device.vendor}" }) unless options[:json]
            plan.selected.empty? || plan.outcomes.compact.any? { |item| !%i[filtered sample_limit].include?(item.status) } ? 1 : 0
          end

          # 仅为未显式设置的选项补充示例配置和备份目录。
          def apply_defaults(options)
            values = options.fetch(:environment)
            values["NC_CONFIG"] = @default_config if @default_config && !values.key?("NC_CONFIG") && !@env.key?("NC_CONFIG")
            return unless @default_directory && !values.key?("NC_BACKUP_DIRECTORY") && !@env.key?("NC_BACKUP_DIRECTORY")

            path = values["NC_CONFIG"] || @env["NC_CONFIG"]
            document = path && File.file?(path) ? Config.load(path) : {}
            values["NC_BACKUP_DIRECTORY"] = @default_directory unless document.key?("NC_BACKUP_DIRECTORY")
          end

          # 配置不存在时生成并验证初始文件；本次运行到此结束，不继续连接设备。
          def initialize_config?(options)
            Setup.new(mode: @mode, options: options, env: @env, input: @input, output: @error,
                      env_path: @default_env, directory: @default_directory, load_env: @load_env).initialize_files?
          end

          # 清单离线回退和本地保存故障单独提示，不覆盖设备操作结果。
          def inventory_warning(fleet)
            if fleet.inventory_status && fleet.inventory_status[:source] == :stale_cache
              @error.puts "清单刷新失败，使用历史缓存（#{fleet.inventory_status[:refresh_error_code]}）"
            end
            return unless fleet.inventory_status && fleet.inventory_status[:write_error_type]
            @error.puts "清单缓存写入失败（#{fleet.inventory_status[:write_error_type]}）"

          end

          # 预检完成后才创建批次目录；补充日志路径时保持原策略快照与动态凭据来源。
          def prepare(options)
            settings = CLI::Options.settings(options, env: @env, load_env: @load_env).for_run(mode: @mode)
            success_policy = options.fetch(:success_policy, :selected)
            raise ArgumentError, "verified policy requires TFTP mode" if success_policy == :verified && @mode != :tftp
            raise ArgumentError, "--tftp-root requires TFTP mode" if options[:tftp_root] && @mode != :tftp
            server_root = tftp_root(settings, options) if @mode == :tftp && !options[:inventory_only]
            if success_policy == :verified && !server_root && settings.tftp_verification_roots.empty?
              raise ArgumentError, "verified policy requires a local TFTP directory"
            end
            Tftp::Verifier.new(root: server_root) if server_root
            settings = settings.with_overrides("NC_TFTP_ROOT" => server_root) if server_root
            batch_directory = Storage::BatchDirectory.create(settings.backup_directory) unless options[:plan] || options[:inventory_only]
            if batch_directory && @mode == :tftp && !settings.log_directory
              settings = settings.with_overrides("NC_LOG_DIRECTORY" => File.join(batch_directory, "logs"))
            end
            [settings, success_policy, server_root, batch_directory]
          end

          # 事件流仅记录受控元数据；计划写入后在有界工作线程中执行同一批设备。
          def execute(fleet, settings, plan, batch_directory, progress, success_policy, server_root)
            File.open(File.join(batch_directory, "events.jsonl"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |events|
              options = { plan: plan, parallel: settings.parallel, success_policy: success_policy,
                          on_start: progress.method(:start), on_result: result_callback(progress, events) }
              progress.with_updates do
                if @mode == :backup
                  fleet.backup_all(directory: batch_directory, filename_style: :hostname_ip, **options)
                else
                  fleet.tftp_backup_all(server: settings.tftp_server, source_files: settings.tftp_source_files,
                                        vrfs: settings.tftp_vrfs, report_directory: batch_directory,
                                        verification_root: server_root, preserve_history: true, **options)
                end
              end
            end
          end

          # 将任务结果追加到私有事件流并更新进度；异常由工作线程保留为回调诊断。
          def result_callback(progress, events)
            lock = Mutex.new
            lambda do |outcome|
              progress.result(outcome)
              lock.synchronize do
                events.puts JSON.generate(host: outcome.device.host, vendor: outcome.device.vendor,
                                           status: outcome.status, error_code: outcome.diagnostic&.error_code,
                                           error_type: outcome.diagnostic&.error_type, duration_ms: outcome.duration_ms,
                                           artifact: outcome.backup&.to_h)
                events.flush
              end
            end
          end

          # 工作线程已停止后保存部分回执；保存或显示失败都不能改变取消退出码。
          def finish_interrupted(fleet, progress, options, directory, plan, settings)
            report = fleet&.last_report
            return unless report && report.status == :interrupted && directory && plan

            report = record_progress_error(report, progress)
            report = Report::Files.write(report, directory: directory, plan: plan, parallel: settings.parallel)
            finish(report, progress, options, directory, plan, settings.parallel)
          rescue StandardError, Interrupt
            # 部分文件可能已经提交；不重复设备操作，仍以原中断结束。
            nil
          end

          # 报告先保存，再显示完成信息；终端收尾失败只补写诊断，不重放任务。
          def finish(report, progress, options, batch_directory, plan, parallel)
            progress.finish(report)
            progress.location(report.report_location) if report.report_location
            summary_path = File.join(batch_directory, "summary.txt")
            progress.location(summary_path, label: "文本报告") if File.file?(summary_path)
            updated = record_progress_error(report, progress)
            unless updated.equal?(report)
              # 末尾显示也可能首次失败，只补写诊断，不重复设备任务或事件。
              report = Report::Files.write(updated, directory: batch_directory, plan: plan, parallel: parallel)
            end
            if options[:json]
              @output.puts JSON.generate(directory: batch_directory, counts: report.counts,
                                         tasks_succeeded: report.policy_success?, success: report.policy_success?,
                                         policy: report.policy, policy_success: report.policy_success?,
                                         exit_status: report.status == :interrupted ? 130 : (report.policy_success? ? 0 : 1),
                                         report_location: report.report_location, report_error: report.report_error)
            end
            report.policy_success? ? 0 : 1
          end

          # 输出故障只记录一次，保留已有批次结果和回调错误。
          def record_progress_error(report, progress)
            return report unless progress.output_error && !report.callback_errors.include?(progress.output_error)

            report.with(callback_errors: [*report.callback_errors, progress.output_error].freeze)
          end

          # 优先使用显式核验根目录；仅服务器是本机地址时探测本机惯用 TFTP 目录。
          def tftp_root(settings, options)
            server = settings.tftp_server
            if !server && settings.tftp_servers.empty?
              raise ArgumentError, "YAML tftp.server or tftp.servers is required"
            end
            return options[:tftp_root] || settings.tftp_root if options[:tftp_root] || settings.tftp_root
            return unless server && Socket.ip_address_list.any? { |address| address.ip_address == server }

            candidate = File.join(Dir.home, "Documents", "TFTP")
            candidate if File.directory?(candidate)
          end

          # 预览来自已有计划，文件名按本次模式计算，不重新请求清单或设备。
          def plan_summary(plan)
            { total: plan.inventory.size, ready: plan.inventory.count(&:ready?),
              vendors: plan.inventory.group_by { |device| device.vendor || :unmapped }.transform_values(&:size),
              issues: plan.inventory.reject(&:ready?).group_by(&:issue).transform_values(&:size),
              selected: plan.selected.map do |device|
                filename = plan.mode == :backup ? device.backup_filename(style: :hostname_ip) : device.tftp_filename
                entry = { host: device.host, name: device.name, vendor: device.vendor, backup_filename: filename }
                entry[:transfer] = plan.transfers.fetch(device.host).to_h if plan.mode == :tftp && plan.transfers.key?(device.host)
                entry
              end }
          end
        end
      end
    end
  end
end
