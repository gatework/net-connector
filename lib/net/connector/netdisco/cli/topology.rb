# frozen_string_literal: true

require "json"
require "digest"
require_relative "options"
require_relative "credentials"
require_relative "../fleet"
require_relative "../progress"
require_relative "../config_initializer"
require_relative "../../storage/batch_directory"

module Net
  module Connector
    module Netdisco
      class CLI
        # 只读默认的拓扑应用入口；计划先持久化，显式 apply 仍通过设备层重验及保存。
        class Topology
          def initialize(default_config: nil, default_directory: nil, argv: ARGV, env: ENV, input: $stdin,
                         output: $stdout, error: $stderr, connector_factory: nil, environment_defaults: false)
            @default_config, @default_directory = default_config, default_directory
            @argv, @env, @input, @output, @error = argv, env, input, output, error
            @environment_defaults = environment_defaults
            @connector_factory = connector_factory || ->(device, options) { device.build_connector(**options) }
          end

          def run
            @initialized = false
            @events_mutex = @task_results = nil
            options = parse_options
            return 0 if options[:help]

            settings = settings_for(options)
            return 0 if @initialized

            policy = settings.topology_options
            raise ArgumentError, "topology apply requires explicit --apply" if policy.mode == :apply && !options[:apply]

            inventory, credentials = CLI::Credentials.resolve(settings, input: @input, stdin_credentials: options[:stdin_credentials])
            @progress = Progress.new(io: @error, enabled: !options[:no_progress], verbose: options[:verbose])
            @progress.reading_inventory
            fleet = Fleet.new(inventory: inventory, settings: settings, report_store: nil)
            devices = fleet.devices(force_refresh: options[:force_refresh] || false)
            return inventory_preview(devices, options) if options[:inventory_only]
            return 1 if policy.mode == :apply && options[:stdin_credentials] && @input.gets("\n")&.strip != "RUN"

            execute(devices, settings, credentials, policy, options)
          rescue Interrupt
            130
          rescue ArgumentError, Inventory::Error, EOFError => exception
            @error.puts "拓扑参数或清单错误：#{exception.message}"
            2
          rescue StandardError => exception
            @error.puts "拓扑未完成（#{Error::Metadata.type(exception.class.name) || "StandardError"}）"
            2
          end

          private

          def parse_options
            CLI::Options.parse(argv: @argv, input: @input, output: @output, error: @error, mode: :topology)
          end

          def settings_for(options)
            environment = options.fetch(:environment)
            environment["NC_CONFIG"] ||= @default_config if @default_config && !@env["NC_CONFIG"]
            path = environment["NC_CONFIG"] || @env["NC_CONFIG"]
            initialize_config(path, options) if path && !File.exist?(path) && !File.symlink?(path)
            settings = CLI::Options.settings(options, env: @env, environment_defaults: @environment_defaults)
            policy = settings.topology_options
            overrides = topology_overrides(options, policy)
            @settings = settings.with_overrides(overrides).for_run(mode: :topology)
          end

          def topology_overrides(options, policy)
            values = { "ND_CACHE_MODE" => policy.cache_mode.to_s }
            values["NC_TOPOLOGY_MODE"] = options[:topology_mode].to_s if options[:topology_mode]
            values["NC_TOPOLOGY_LIMIT"] = options[:topology_limit].to_s if options[:topology_limit]
            explicit = options.fetch(:environment)
            values["NC_TOPOLOGY_DIRECTORY"] = explicit["NC_BACKUP_DIRECTORY"] || policy.directory || @default_directory
            values.delete("NC_TOPOLOGY_DIRECTORY") unless values["NC_TOPOLOGY_DIRECTORY"]
            values["NC_TOPOLOGY_CONCURRENCY"] = explicit["NC_CONCURRENCY"] if explicit["NC_CONCURRENCY"]
            values["ND_CACHE_MODE"] = explicit["ND_CACHE_MODE"] if explicit["ND_CACHE_MODE"]
            values
          end

          def initialize_config(path, options)
            document = { "topology" => { "mode" => "plan", "cache_mode" => "prefer", "concurrency" => 4 } }
            document["topology"]["directory"] = @default_directory if @default_directory
            ConfigInitializer.new(input: @input, output: @error).create(path: path, document: document, interactive: options[:interactive])
            @error.puts "已初始化配置：#{path}；检查配置后再次运行。"
            # 新建配置不能继续访问清单；由 run 入口处理这个明确状态。
            @initialized = true
          end

          def inventory_preview(devices, options)
            selected = devices.select(&:ready?)
            data = { devices: selected.map { |device| { host: device.host, name: device.name, vendor: device.vendor } } }
            display(data, options)
            selected.empty? ? 1 : 0
          end

          def execute(devices, settings, credentials, policy, options)
            raise ArgumentError, "topology.directory or --directory is required" unless policy.directory

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
            @progress.operation_plan(selected, concurrency: policy.concurrency, label: "拓扑发现/规划")
            outcomes = @progress.with_updates { collect(selected, settings, credentials, policy, directory) }
            save_plan(directory, outcomes)
            if policy.mode == :apply
              applying = outcomes.filter_map { |outcome| @devices_by_host[outcome[:host]] if %i[planned partial_planned].include?(outcome[:status]) }
              @progress.operation_plan(applying, concurrency: policy.concurrency, label: "拓扑应用")
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

          def collect(devices, settings, credentials, policy, directory)
            Net::Connector::Concurrency::Pool.new(concurrency: policy.concurrency).map(devices) do |device|
              unless discovery_supported?(device)
                next observe_task(device, directory) { { host: device.host, vendor: device.vendor, status: :unsupported_operation } }
              end
              perform(device, settings, credentials, directory) do |connector|
                audit = connector.audit_interface_descriptions(abbreviate: policy.abbreviate_ports, lowercase: policy.lowercase_ports,
                                                                 &formatter(policy))
                audit_outcome(audit, device, policy)
              end
            end
          end

          def discovery_supported?(device)
            strategy = Net::Connector.vendor_class(device.vendor).profile.topology_strategy
            strategy&.supports?(:neighbors)
          end

          def formatter(policy)
            lambda do |neighbor|
              port = neighbor.neighbor_interface
              port = Net::Connector::Topology::InterfaceName.short(port) if policy.abbreviate_ports
              port = port.downcase if policy.lowercase_ports
              policy.format(neighbor: neighbor.neighbor_name, port: port)
            end
          end

          def audit_outcome(audit, device, policy)
            raise TypeError, "topology audit must return an Audit" unless audit.instance_of?(Net::Connector::Topology::Audit)
            plan = audit.plan
            if plan && (plan.host != device.host || plan.vendor != device.vendor)
              raise ArgumentError, "topology plan does not match its inventory device"
            end
            Net::Connector::Topology.validate_plan!(plan, host: device.host, vendor: device.vendor) if plan
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

          def observed_credentials(credentials)
            ->(device) { credentials.call(device)&.merge(on_event: @progress.method(:event)) }
          end

          def attach_progress_error(summary)
            return unless @progress.output_error

            summary[:progress_error] = @progress.output_error
            summary[:success] = false
          end

          def perform(device, settings, credentials, directory, &)
            observe_task(device, directory) { perform_value(device, settings, credentials, directory, &) }
          end

          def observe_task(device, directory)
            started_at = Time.now.utc
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = nil
            begin
              @progress.start(device, label: "拓扑操作")
              result = yield
            rescue StandardError => failure
              result = { host: device.host, vendor: device.vendor, status: :failed, diagnostic: Diagnostic.from(failure)&.to_h }
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

          def complete_task(device, result, directory, started_at, started)
            result ||= @events_mutex.synchronize { @task_results[device.host]&.except(:plan) }&.merge(status: :interrupted)
            result ||= { host: device.host, vendor: device.vendor, status: :interrupted }
            result.merge!(started_at: started_at.iso8601, finished_at: Time.now.utc.iso8601,
                          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
            append_event(directory, result)
            @events_mutex.synchronize { @task_results[device.host] = result }
            @progress.operation_result(device: device, status: result[:status], duration_ms: result[:duration_ms],
                                       error_code: result.dig(:diagnostic, :error_code), neighbors: result.fetch(:neighbors, []).size,
                                       changes: result.fetch(:changes, 0))
          end

          def save_plan(directory, outcomes)
            plans = outcomes.filter_map { |outcome| outcome[:plan] }.map do |plan|
              { host: plan.host, vendor: plan.vendor, evidence: plan.evidence, scope: plan.scope, commands: plan.commands,
                changes: plan.changes.map { |change| change.to_h.merge(neighbor: change.neighbor.to_h) } }
            end
            contents = JSON.pretty_generate(devices: plans, audits: outcomes.map { |outcome| outcome.except(:plan) })
            path = File.join(directory, "plan.json")
            Storage::AtomicFile.write(path, contents)
            Storage::AtomicFile.write(path + ".sha256", Digest::SHA256.hexdigest(contents) + "\n")
          end

          def apply_plans(outcomes, settings, credentials, policy, directory)
            Net::Connector::Concurrency::Pool.new(concurrency: policy.concurrency).map(outcomes) do |outcome|
              next outcome unless %i[planned partial_planned].include?(outcome[:status]) && outcome[:plan]

              plan = outcome.fetch(:plan)
              device = @devices_by_host.fetch(plan.host)
              perform(device, settings, credentials, directory) do |connector|
                result = connector.apply_interface_descriptions(plan, confirmed: true)
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

          def build_summary(devices, outcomes, policy, directory)
            unexpected = devices.any? { |device| device.issue && device.issue != :filtered }
            good = %i[planned discovered applied]
            attempted = outcomes.reject { |outcome| outcome[:status] == :unsupported_operation }
            success = !attempted.empty? && !unexpected && outcomes.all? do |outcome|
              (good.include?(outcome[:status]) || outcome[:status] == :unsupported_operation) && !outcome[:event_error_type] && (policy.mode != :plan || outcome.fetch(:changes, 0).zero?)
            end
            { mode: policy.mode, success: success, directory: directory,
              counts: outcomes.map { |outcome| outcome[:status] }.tally,
              inventory: devices.map { |device| { host: device.host, vendor: device.vendor, issue: device.issue } },
              devices: outcomes.map { |outcome| outcome.except(:plan) } }
          end

          def persist_summary(directory, summary)
            Storage::AtomicFile.write(File.join(directory, "summary.json"), JSON.pretty_generate(summary))
            lines = summary[:devices].flat_map do |item|
              ["#{item[:host]} #{item[:status]} changes=#{item.fetch(:changes, 0)}"] +
                item.fetch(:neighbors, []).map do |row|
                  "  #{row[:interface]} #{row[:status]} current=#{row[:current].inspect} expected=#{row[:expected].inspect}"
                end + item.fetch(:issues, []).map { |issue| "  #{issue[:interface]} issue=#{issue[:code]}" } +
                item.fetch(:commands, []).map { |command| "  command=#{command.inspect}" }
            end
            Storage::AtomicFile.write(File.join(directory, "summary.txt"), lines.join("\n") + "\n")
          end

          def append_event(directory, result)
            @events_mutex.synchronize do
              File.open(File.join(directory, "events.jsonl"), File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600) do |file|
                file.puts JSON.generate(result.except(:plan))
              end
            end
          rescue StandardError => failure
            result[:event_error_type] = Error::Metadata.type(failure.class.name) || "StandardError"
          end

          def display(data, options)
            if options[:json]
              @output.puts JSON.generate(data)
            else
              data.fetch(:devices).each { |item| @output.puts "#{item[:host]}\t#{item[:status] || item[:name]}" }
              @output.puts "报告：#{data[:directory]}" if data[:directory]
            end
          end
        end
      end
    end
  end
end
