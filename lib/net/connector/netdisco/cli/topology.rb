# frozen_string_literal: true

require "json"
require "digest"
require_relative "options"
require_relative "credentials"
require_relative "../fleet"
require_relative "../progress"
require_relative "setup"
require_relative "../../storage/batch_directory"
require_relative "../resources"
require_relative "../topology/files"
require_relative "../topology/presentation"

module Net
  module Connector
    module Netdisco
      class CLI
        # 只读默认的拓扑应用入口；计划先持久化，显式 apply 仍通过设备层重验及保存。
        class Topology
          # 保存拓扑入口默认配置、输入输出和连接器工厂，暂不访问清单。
          def initialize(default_config: nil, default_directory: nil, argv: ARGV, env: ENV, input: $stdin,
                         output: $stdout, error: $stderr, connector_factory: nil, default_env: nil, load_env: false)
            @default_config, @default_directory = default_config, default_directory
            @argv, @env, @input, @output, @error = argv, env, input, output, error
            @load_env, @default_env = load_env, default_env
            @connector_factory = connector_factory || ->(device, options) { device.build_connector(**options) }
          end

          # 固定策略后读取清单，执行预览或拓扑批次，并将取消与参数错误映射为退出码。
          def run
            @initialized = false
            @events_mutex = @task_results = nil
            options = parse_options
            return 0 if options[:help]

            settings = settings_for(options)
            return 0 if @initialized

            policy = settings.topology_options
            raise ArgumentError, "应用配置必须显式传入 --apply；--plan 仅生成计划，--discover 只读发现" if policy.mode == :apply && !options[:apply]

            inventory, credentials = CLI::Credentials.resolve(settings, input: @input, stdin_credentials: options[:stdin_credentials])
            @progress = Progress.new(io: @error, enabled: !options[:no_progress], verbose: options[:verbose])
            @progress.reading_inventory(config: options.fetch(:environment)["NC_CONFIG"] || @env["NC_CONFIG"])
            fleet = Fleet.new(inventory: inventory, settings: settings, report_store: nil)
            devices = fleet.devices(force_refresh: options[:force_refresh] || false)
            inventory_warning(fleet)
            return inventory_preview(devices, options) if options[:inventory_only]
            return 1 if policy.mode == :apply && options[:stdin_credentials] && @input.gets("\n")&.strip != "RUN"

            execute(devices, settings, credentials, policy, options)
          rescue Interrupt
            130
          rescue EOFError
            @error.puts "配置输入未完成，已停止；请检查先前提示的文件。"
            2
          rescue ArgumentError, Inventory::Error => exception
            @error.puts "拓扑参数或清单错误：#{exception.message}"
            2
          rescue StandardError => exception
            @error.puts "拓扑未完成（#{Error::Metadata.type(exception.class.name) || "StandardError"}）"
            2
          end

          private

          # 使用共享解析器读取拓扑模式参数，不修改调用方的参数数组。
          def parse_options
            CLI::Options.parse(argv: @argv, input: @input, output: @output, error: @error, mode: :topology)
          end

          # 解析配置与 CLI 覆盖并固定拓扑策略；首次生成配置后停止执行。
          def settings_for(options)
            environment = options.fetch(:environment)
            environment["NC_CONFIG"] ||= @default_config if @default_config && !@env["NC_CONFIG"]
            @initialized = Setup.new(mode: :topology, options: options, env: @env, input: @input, output: @error,
                                     env_path: @default_env, directory: @default_directory, load_env: @load_env).initialize_files?
            return if @initialized
            settings = CLI::Options.settings(options, env: @env, load_env: @load_env)
            policy = settings.topology_options
            overrides = topology_overrides(options, policy)
            @settings = settings.with_overrides(overrides).for_run(mode: :topology)
          end

          # 按 CLI、配置与示例默认值组合拓扑输出、并发和缓存选项。
          def topology_overrides(options, policy)
            values = { "ND_CACHE_MODE" => policy.cache_mode.to_s }
            values["NC_TOPOLOGY_MODE"] = options[:topology_mode].to_s if options[:topology_mode]
            values["NC_TOPOLOGY_LIMIT"] = options[:topology_limit].to_s if options[:topology_limit]
            explicit = options.fetch(:environment)
            values["NC_TOPOLOGY_DIRECTORY"] = explicit["NC_BACKUP_DIRECTORY"] || policy.directory || @default_directory
            values.delete("NC_TOPOLOGY_DIRECTORY") unless values["NC_TOPOLOGY_DIRECTORY"]
            values["NC_TOPOLOGY_PARALLEL"] = explicit["NC_PARALLEL"] if explicit["NC_PARALLEL"]
            values["ND_CACHE_MODE"] = explicit["ND_CACHE_MODE"] if explicit["ND_CACHE_MODE"]
            values
          end

          # 缓存回退和写入失败与备份入口一致提示，不把历史清单当作远端恢复。
          def inventory_warning(fleet)
            status = fleet.inventory_status
            return unless status

            @error.puts "清单刷新失败，使用历史缓存（#{status[:refresh_error_code]}）" if status[:source] == :stale_cache
            @error.puts "清单缓存写入失败（#{status[:write_error_type]}）" if status[:write_error_type]
          end

          # 仅预览就绪清单，不建立设备连接；无选中设备时返回未完成。
          def inventory_preview(devices, options)
            selected = devices.select(&:ready?)
            data = { total: devices.size, ready: selected.size,
                     issues: devices.reject(&:ready?).group_by(&:issue).transform_values(&:size),
                     devices: selected.map { |device| { host: device.host, name: device.name, vendor: device.vendor } } }
            display(data, options)
            selected.empty? ? 1 : 0
          end

          # 先发现并保存审批计划，仅在显式应用模式执行变更，失败后保存已有任务回执。
          # 发现结果先落盘并生成校验摘要，再进入应用；取消只汇总回执，不重新下发配置。
          def execute(devices, settings, credentials, policy, options)
            raise ArgumentError, "请在 topology.directory 或 --directory 设置拓扑报告目录" unless policy.directory

            directory = Storage::BatchDirectory.create(policy.directory)
            selected = devices.select(&:ready?)
            if policy.limit
              capable, unsupported = selected.partition { |device| discovery_supported?(device) }
              selected = capable.first(policy.limit) + unsupported
            end
            @devices_by_host = selected.to_h { |device| [device.host, device] }
            @events_mutex = Mutex.new
            @task_results = {}
            credentials = observed_credentials(credentials)
            @progress.operation_plan(selected, parallel: policy.parallel, label: "拓扑发现/规划")
            outcomes = @progress.with_updates { collect(selected, settings, credentials, policy, directory) }
            save_plan(directory, outcomes)
            if policy.mode == :apply
              applying = outcomes.filter_map { |outcome| @devices_by_host[outcome[:host]] if %i[planned partial_planned].include?(outcome[:status]) }
              @progress.operation_plan(applying, parallel: policy.parallel, label: "拓扑应用")
              outcomes = @progress.with_updates { apply_plans(outcomes, settings, credentials, policy, directory) }
            end
            summary = build_summary(devices, outcomes, policy, directory)
            @progress.finish_operations(success: summary[:success], counts: summary[:counts])
            attach_progress_error(summary)
            persist_summary(directory, summary)
            display(summary, options)
            summary[:success] ? 0 : 1
          rescue Interrupt, StandardError => failure
            # Pool 已回收所有工作线程；此时才能稳定地读取任务收尾登记的回执。
            # 报告失败不能替换取消或最先观察到的编排故障。
            begin
              persist_aborted(directory, devices, selected, policy, failure) if @events_mutex && directory
            rescue Exception # rubocop:disable Lint/RescueException -- 保留原始取消或编排故障。
              nil
            end
            raise
          end

          # 在线程池停止后汇总已完成和未开始任务，持久化中断或编排失败摘要。
          def persist_aborted(directory, devices, selected, policy, failure)
            outcomes = @events_mutex.synchronize do
              selected.map do |device|
                @task_results[device.host] || { host: device.host, vendor: device.vendor, status: :not_started }
              end
            end
            summary = build_summary(devices, outcomes, policy, directory)
            summary[:success] = false
            if failure.is_a?(Interrupt)
              summary[:interrupted] = true
            else
              summary[:orchestration_error_type] = Error::Metadata.type(failure.class.name) || "StandardError"
            end
            attach_progress_error(summary)
            persist_summary(directory, summary)
          end

          # 并发读取支持发现能力的设备，逐设备生成接口描述审计与候选计划。
          def collect(devices, settings, credentials, policy, directory)
            Resources.prepare!(parallel: [policy.parallel, devices.size].min)
            Net::Connector::Parallel::Pool.new(parallel: policy.parallel).map(devices) do |device|
              unless discovery_supported?(device)
                next observe_task(device, directory) { { host: device.host, vendor: device.vendor, status: :unsupported_operation } }
              end
              perform(device, settings, credentials, directory) do |connector|
                audit = connector.interfaces.audit(abbreviate: policy.abbreviate_ports, lowercase: policy.lowercase_ports,
                                                                 description_matcher: policy.method(:description_matches?),
                                                                 &formatter(policy))
                audit_outcome(audit, device, policy)
              end
            end
          end

          # 只检查厂商是否声明邻居发现能力，不建立设备连接。
          def discovery_supported?(device)
            strategy = Net::Connector.vendor_class(device.vendor).profile.topology_strategy
            strategy&.supports?(:neighbors)
          end

          # 构造邻居描述格式化回调，按策略缩写或转换远端端口名称。
          def formatter(policy)
            policy.method(:description_for)
          end

          # 将接口审计转换为规划、发现或需人工处理的任务结果。
          def audit_outcome(audit, device, policy)
            raise TypeError, "topology audit must return an Audit" unless audit.instance_of?(Net::Connector::Interfaces::Audit)
            plan = audit.plan
            if plan && (plan.host != device.host || plan.vendor != device.vendor)
              raise ArgumentError, "topology plan does not match its inventory device"
            end
            Net::Connector::Interfaces.validate_plan!(plan, host: device.host, vendor: device.vendor) if plan
            status = if !audit.complete?
                       plan && !plan.changes.empty? && policy.mode != :discover ? :partial_planned : :unverified
                     elsif policy.mode == :discover
                       :discovered
                     elsif audit.manual_required
                       :manual_required
                     else
                       plan ? :planned : :discovered
                     end
            { plan: policy.mode == :discover ? nil : plan, status: status, neighbors: comparison_rows(audit, policy),
              issues: audit.issues, changes: audit.changes, commands: policy.mode == :discover ? [] : (plan&.commands || []) }
          end

          # 在内容不一致时进一步检查描述模板，区分格式不符与普通差异。
          def comparison_rows(audit, policy)
            pattern = Regexp.escape(policy.description_format).gsub("%\\{neighbor\\}", ".+").gsub("%\\{port\\}", ".+")
            audit.comparisons.map do |entry|
              if entry[:status] == :content_mismatch && !entry[:current].match?(/\A#{pattern}\z/)
                entry.merge(status: :format_mismatch)
              else
                entry
              end
            end
          end

          # 为原有逐设备凭据回调附加进度事件观察，不改变认证内容。
          def observed_credentials(credentials)
            ->(device) { credentials.call(device)&.merge(on_event: @progress.method(:event)) }
          end

          # 将终端显示故障纳入摘要，阻止有诊断丢失的批次报告成功。
          def attach_progress_error(summary)
            return unless @progress.output_error

            summary[:progress_error] = @progress.output_error
            summary[:success] = false
          end

          # 在统一计时和完成事件作用域内执行单设备拓扑操作。
          def perform(device, settings, credentials, directory, &)
            observe_task(device, directory) { perform_value(device, settings, credentials, directory, &) }
          end

          # 隔离普通设备错误，并在取消时仍登记完成事件后传播原始中断。
          def observe_task(device, directory)
            started_at = Time.now.utc
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = nil
            begin
              # 阻塞 I/O 仍可取消；完成值或同步失败先固定，再交付返回间隙中的异步中断。
              Thread.handle_interrupt(Exception => :on_blocking) do
                @progress.start(device, label: "拓扑操作")
                result = yield
              rescue StandardError => failure
                result = { host: device.host, vendor: device.vendor, status: :failed, diagnostic: Diagnostic.from(failure)&.to_h }
              end
            rescue Exception => failure # rubocop:disable Lint/RescueException -- 完成事件仍须记录，取消随后传播。
              primary = failure
              raise
            ensure
              begin
                Thread.handle_interrupt(Exception => :never) { complete_task(device, result, directory, started_at, started) }
              rescue Exception => failure # rubocop:disable Lint/RescueException -- 记录故障不能覆盖最先发生的取消。
                raise failure unless primary
              end
            end
            result
          end

          # 解析设备接入设置，在独占连接作用域内执行操作并保留部分返回值。
          def perform_value(device, settings, credentials, directory, &)
            access = Device::Access.resolve(device, settings: settings, credentials: credentials, policy: settings,
                                            log_directory: settings.log_directory || File.join(directory, "logs"))
            return { host: device.host, vendor: device.vendor, status: :missing_credentials } unless access

            FileUtils.mkdir_p(File.dirname(access.fetch(:log_file)), mode: 0o700)
            value, error = Net::Connector::Device::Scope.call(factory: -> { @connector_factory.call(device, access) }, &)
            error = value&.delete(:operation_error) || error
            result = { host: device.host, vendor: device.vendor, session_log: access[:log_file] }.merge(value || {})
            if error
              result[:status] = value ? :partial : :failed unless %i[partial failed].include?(result[:status])
              result[:diagnostic] = Diagnostic.from(error)&.to_h
            end
            result
          end

          # 登记任务时间、事件和进度；被取消的任务保留先前可用的操作证据。
          def complete_task(device, result, directory, started_at, started)
            result ||= @events_mutex.synchronize { @task_results[device.host]&.except(:plan) }&.merge(status: :interrupted)
            result ||= { host: device.host, vendor: device.vendor, status: :interrupted }
            result.merge!(started_at: started_at.iso8601, finished_at: Time.now.utc.iso8601,
                          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
            append_event(directory, result)
            @events_mutex.synchronize { @task_results[device.host] = result }
            @progress.operation_result(device: device, status: result[:status], duration_ms: result[:duration_ms],
                                       error_code: result.dig(:diagnostic, :error_code), neighbors: result.fetch(:neighbors, []).size,
                                       changes: result.fetch(:changes, 0), issues: result.fetch(:issues, []))
          end

          # 原子保存设备审批计划及其 SHA-256，应用之前先固定可复核证据。
          def save_plan(directory, outcomes)
            outcomes.each do |outcome|
              Netdisco::Topology::Files.write_plan(directory: directory, device: @devices_by_host.fetch(outcome[:host]), outcome: outcome)
            end
            plans = outcomes.filter_map do |outcome|
              plan = outcome[:plan]
              next unless plan

              { host: plan.host, name: outcome[:name], vendor: plan.vendor, evidence: plan.evidence, scope: plan.scope,
                commands: plan.commands, script_file: outcome[:script_file], script_sha256: outcome[:script_sha256],
                device_report: outcome[:device_report], changes: plan.changes.map { |change| change.to_h.merge(neighbor: change.neighbor.to_h) } }
            end
            contents = JSON.pretty_generate(devices: plans, audits: outcomes.map { |outcome| outcome.except(:plan) })
            path = File.join(directory, "plan.json")
            Storage::AtomicFile.write(path, contents)
            Storage::AtomicFile.write(path + ".sha256", Digest::SHA256.hexdigest(contents) + "\n")
          end

          # 仅应用已规划的设备，并保留现场核验、已执行步骤和部分失败状态。
          def apply_plans(outcomes, settings, credentials, policy, directory)
            Resources.prepare!(parallel: [policy.parallel, outcomes.size].min)
            Net::Connector::Parallel::Pool.new(parallel: policy.parallel).map(outcomes) do |outcome|
              next outcome unless %i[planned partial_planned].include?(outcome[:status]) && outcome[:plan]

              plan = outcome.fetch(:plan)
              device = @devices_by_host.fetch(plan.host)
              perform(device, settings, credentials, directory) do |connector|
                result = connector.interfaces.apply(plan, confirmed: true)
                raise TypeError, "topology application must return a Result" unless result.is_a?(Result)

                status = if result.failure?
                           result.steps.empty? ? :failed : :partial
                         else
                           outcome.fetch(:issues, []).empty? ? :applied : :partial_applied
                         end
                outcome.except(:plan).merge(status: status, changes: plan.changes.size, steps: result.steps.size, operation_error: result.error)
              end
            end
          end

          # 汇总清单覆盖、逐设备结果和事件故障，按当前模式判断是否完成。
          def build_summary(devices, outcomes, policy, directory)
            unexpected = devices.any? { |device| device.issue && device.issue != :filtered }
            good = %i[planned discovered applied]
            attempted = outcomes.reject { |outcome| outcome[:status] == :unsupported_operation }
            success = !attempted.empty? && !unexpected && outcomes.all? do |outcome|
              (good.include?(outcome[:status]) || outcome[:status] == :unsupported_operation) && !outcome[:event_error_type] && (policy.mode != :plan || outcome.fetch(:changes, 0).zero?)
            end
            { mode: policy.mode, success: success, directory: directory,
              counts: outcomes.map { |outcome| outcome[:status] }.tally, statistics: Netdisco::Topology::Presentation.statistics(outcomes),
              inventory: devices.map { |device| { host: device.host, vendor: device.vendor, issue: device.issue } },
              devices: outcomes.map { |outcome| outcome.except(:plan) } }
          end

          # 分别原子写入 JSON 摘要和逐接口可读报告。
          def persist_summary(directory, summary)
            Storage::AtomicFile.write(File.join(directory, "summary.json"), JSON.pretty_generate(summary))
            summary[:devices].each { |outcome| Netdisco::Topology::Files.write_report(outcome) }
            lines = result_lines(summary) + summary[:devices].flat_map do |item|
              ["#{item[:host]} #{item[:name].to_s.gsub(/[[:cntrl:]]/, " ")} #{Netdisco::Topology::Presentation.status(item[:status], changes: item.fetch(:changes, 0))} changes=#{item.fetch(:changes, 0)}",
               "  设备报告：#{item[:device_report]}", "  命令文件：#{item[:script_file] || "未生成"}"] +
                item.fetch(:neighbors, []).map do |row|
                  "  #{row[:interface]} #{row[:status]} current=#{row[:current].inspect} expected=#{row[:expected].inspect}"
                end + item.fetch(:issues, []).map { |issue| "  #{issue[:interface]} #{Netdisco::Topology::Presentation.reason(issue[:code])}" } +
                item.fetch(:commands, []).map { |command| "  command=#{command.inspect}" }
            end
            Storage::AtomicFile.write(File.join(directory, "summary.txt"), lines.join("\n") + "\n")
          end

          # 持锁追加受控任务事件，写入失败时登记诊断而不丢弃设备结果。
          def append_event(directory, result)
            @events_mutex.synchronize do
              File.open(File.join(directory, "events.jsonl"), File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600) do |file|
                file.puts JSON.generate(result.except(:plan))
              end
            end
          rescue StandardError => failure
            result[:event_error_type] = Error::Metadata.type(failure.class.name) || "StandardError"
          end

          # 默认只打印设备、接口两层摘要；逐设备及命令详情已经写入独立报告。
          def result_lines(data)
            stats = data.fetch(:statistics)
            ["结果：#{Netdisco::Topology::Presentation.result(data)}；模式：#{data[:mode]}",
             "设备：采集完成 #{stats[:collected]} 台；无需修改 #{stats[:unchanged]} 台；有候选变更 #{stats[:change_devices]} 台；失败 #{stats[:failed]} 台",
             "接口：候选变更 #{stats[:changes]} 个；待核实 #{stats[:review_interfaces]} 个（涉及 #{stats[:review_devices]} 台设备）",
             "待核实原因：#{Netdisco::Topology::Presentation.issues(data[:devices].flat_map { |item| item.fetch(:issues, []) })}"]
          end

          # 按 JSON 或安全文本格式输出设备结果及报告位置。
          def display(data, options)
            if options[:json]
              @output.puts JSON.generate(data)
            else
              if data.key?(:total)
                @output.puts "清单 #{data[:total]} 台；本次 #{data[:ready]} 台；跳过 #{data[:total] - data[:ready]} 台"
              end
              if data.key?(:total)
                data.fetch(:devices).each do |item|
                  fields = [item[:host], item[:vendor], item[:name]]
                  @output.puts fields.map { |field| field.to_s.gsub(/[[:cntrl:]]/, " ") }.join("\t")
                end
              end
              if data[:directory]
                @output.puts result_lines(data)
                scripts = data[:devices].count { |item| item[:script_file] }
                @output.puts "命令文件：#{File.join(data[:directory], "scripts")}（#{scripts} 台有变更）" if scripts.positive?
                @output.puts "设备报告：#{File.join(data[:directory], "devices")}"
                @output.puts "计划：#{File.join(data[:directory], "plan.json")}"
                @output.puts "报告：#{File.join(data[:directory], "summary.json")}"
                @output.puts "文本报告：#{File.join(data[:directory], "summary.txt")}"
              end
            end
          end
        end
      end
    end
  end
end
