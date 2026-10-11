# frozen_string_literal: true

require "ipaddr"
require "time"
require "fileutils"
require_relative "../execution_pool"
require_relative "../device_session"
require_relative "../device/topology"
require_relative "settings"
require_relative "operation_batch"

module Net
  module Connector
    module Netdisco
      # 配置执行与接口修正共用设备生命周期，各业务仍保留自己的审批和结果。
      class Operations
        DEFAULT_SETTING = Object.new.freeze
        MissingCredentials = Class.new(StandardError)
        private_constant :DEFAULT_SETTING, :MissingCredentials

        def initialize(settings:, inventory:, credentials: nil, connector_factory: nil)
          raise ArgumentError, "inventory must respond to call" unless inventory.respond_to?(:call)
          raise ArgumentError, "credentials must respond to call" unless credentials.nil? || credentials.respond_to?(:call)
          unless connector_factory.nil? || connector_factory.respond_to?(:call)
            raise ArgumentError, "connector_factory must respond to call"
          end

          @settings, @inventory, @credentials = settings, inventory, credentials
          @connector_factory = connector_factory || ->(device, options) { device.build_connector(**options) }
        end

        # 全批脚本先解析并固定，明确确认后才查询清单和读取逐设备凭据。
        def execute_scripts(scripts:, confirmed: false, concurrency: DEFAULT_SETTING, on_start: nil, on_result: nil)
          validate_confirmation!(confirmed)
          tasks = normalize_mapping(scripts, :scripts) do |script|
            script.is_a?(String) ? Script.parse(script) : (script.is_a?(Script) ? script : Script.new(script))
          end
          run(:execute_scripts, tasks, concurrency: concurrency, on_start: on_start, on_result: on_result) do |connector, script|
            result = connector.execute_script(script)
            raise TypeError, "configuration operation must return a Result" unless result.is_a?(Result)

            result
          end
        end

        # 一次调用完成邻居发现与描述同步；每台设备独占会话，普通失败互不影响。
        def sync_interface_descriptions(hosts:, abbreviate: true, lowercase: false, concurrency: DEFAULT_SETTING,
                                        on_start: nil, on_result: nil, &formatter)
          tasks = description_targets(hosts, abbreviate, lowercase)
          run(:sync_interface_descriptions, tasks, concurrency: concurrency, on_start: on_start, on_result: on_result) do |connector, _|
            result = connector.sync_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
            raise TypeError, "description synchronization must return a Result" unless result.is_a?(Result)

            result
          end
        end

        # 规划只读取现场证据；格式化回调并发执行，不承担设备连接或审批职责。
        def plan_interface_descriptions(hosts:, abbreviate: true, lowercase: false, concurrency: DEFAULT_SETTING,
                                        on_start: nil, on_result: nil, &formatter)
          tasks = description_targets(hosts, abbreviate, lowercase)

          run(:plan_interface_descriptions, tasks, concurrency: concurrency, on_start: on_start, on_result: on_result) do |connector, _|
            result = connector.plan_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
            raise TypeError, "description planning must return a Topology::Plan" unless result.is_a?(Topology::Plan)

            copy_plan(result)
          end
        end

        # 审批计划整体复制并验证；单设备应用仍执行现场重验、读回和保存，不直接重放 commands。
        def apply_interface_descriptions(plans:, confirmed: false, concurrency: DEFAULT_SETTING, on_start: nil, on_result: nil)
          validate_confirmation!(confirmed)
          tasks = normalize_mapping(plans, :plans) { |plan| copy_plan(plan) }
          tasks.each do |host, plan|
            raise ArgumentError, "plan host does not match its target" unless normalize_host(plan.host) == host
          end
          run(:apply_interface_descriptions, tasks, concurrency: concurrency, on_start: on_start, on_result: on_result) do |connector, plan|
            result = connector.apply_interface_descriptions(plan, confirmed: true)
            raise TypeError, "description application must return a Result" unless result.is_a?(Result)

            result
          end
        end

        private

        # 规划与同步共用目标校验，整批输入在清单与连接之前固定。
        def description_targets(hosts, abbreviate, lowercase)
          raise ArgumentError, "hosts must be an Array" unless hosts.is_a?(Array)
          unless [abbreviate, lowercase].all? { |value| value == true || value == false }
            raise ArgumentError, "description formatting options must be boolean"
          end

          tasks = normalize_mapping(hosts.to_h { |host| [host, nil] }, :hosts)
          raise ArgumentError, "hosts must be unique" unless tasks.size == hosts.size

          tasks
        end

        def validate_confirmation!(confirmed)
          raise ArgumentError, "configuration changes require confirmed: true" unless confirmed == true
        end

        # 管理地址规范化之后再检查重复，等价的 IPv6 写法不能创建两个并行写会话。
        def normalize_host(host)
          unless host.is_a?(String) && !host.empty? && !host.include?("/")
            raise ArgumentError, "targets must be IP address Strings without a prefix"
          end

          IPAddr.new(host).to_s.freeze
        rescue IPAddr::Error
          raise ArgumentError, "target contains an invalid IP address", cause: nil
        end

        def normalize_mapping(mapping, name)
          raise ArgumentError, "#{name} must be a Hash" unless mapping.is_a?(Hash)

          mapping.each_with_object({}) do |(host, value), tasks|
            host = normalize_host(host)
            raise ArgumentError, "targets must be unique" if tasks.key?(host)

            tasks[host] = block_given? ? yield(value) : value
          end.freeze
        end

        # 外部审批容器不与执行共享可变子对象，非法领域结构在任何连接前拒绝。
        def copy_plan(plan)
          raise ArgumentError, "plans must contain Topology::Plan values" unless plan.is_a?(Topology::Plan)
          normalize_host(plan.host)
          unless Net::Connector.vendors.include?(plan.vendor) && plan.evidence.is_a?(Hash) &&
                 plan.changes.is_a?(Array) && plan.commands.is_a?(Array) && plan.commands.all?(String)
            raise ArgumentError, "description plan contains invalid fields"
          end
          commands = Script.new(plan.commands).map { |command| command.text.dup.freeze }.freeze
          evidence = plan.evidence.to_h do |interface, fields|
            unless interface.is_a?(String) && fields.is_a?(Array) && fields.size == 3 && fields.all?(String)
              raise ArgumentError, "description plan contains invalid evidence"
            end
            [interface.dup.freeze, fields.map { |field| field.dup.freeze }.freeze]
          end.freeze
          changes = plan.changes.map { |change| copy_change(change) }.freeze
          raise ArgumentError, "empty description plan cannot contain commands" if changes.empty? && !commands.empty?

          Topology::Plan.new(host: normalize_host(plan.host), vendor: plan.vendor, evidence: evidence,
                             changes: changes, commands: commands).freeze
        end

        def copy_change(change)
          unless change.is_a?(Topology::Change) && change.old_description.is_a?(String) &&
                 change.neighbor.is_a?(Topology::Neighbor) && change.neighbor.to_h.values.all? { |value| value.is_a?(String) || value.is_a?(Symbol) }
            raise ArgumentError, "description plan contains an invalid change"
          end
          Topology::InterfaceDescription.validate_interface!(change.interface)
          Topology::InterfaceDescription.validate!(change.new_description)
          neighbor = Topology::Neighbor.new(**change.neighbor.to_h.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }).freeze
          Topology::Change.new(interface: change.interface.dup.freeze, old_description: change.old_description.dup.freeze,
                               new_description: change.new_description.dup.freeze, neighbor: neighbor).freeze
        end

        # 策略只固定一次；清单与连接使用同一快照，凭据仍在每台任务开始时动态读取。
        def run(operation, tasks, concurrency:, on_start:, on_result:)
          [on_start, on_result].each do |callback|
            raise ArgumentError, "callbacks must respond to call" unless callback.nil? || callback.respond_to?(:call)
          end
          ExecutionPool.validate_concurrency!(concurrency) unless concurrency.equal?(DEFAULT_SETTING)
          snapshot = @settings.snapshot(mode: :inventory)
          concurrency = snapshot.concurrency if concurrency.equal?(DEFAULT_SETTING)
          ExecutionPool.validate_concurrency!(concurrency)
          return empty_batch(operation) if tasks.empty?

          devices = select_devices(tasks, snapshot)
          FileUtils.mkdir_p(snapshot.log_directory, mode: 0o700) if snapshot.log_directory
          started_at = Time.now.utc
          callback_errors = Queue.new
          outcomes = ExecutionPool.new(concurrency: concurrency).map(devices) do |device|
            perform(device, snapshot, callback_errors, on_start, on_result) { |connector| yield connector, tasks.fetch(device.host) }
          end
          errors = Array.new(callback_errors.size) { callback_errors.pop }
          OperationBatch.new(operation: operation, outcomes: outcomes, callback_errors: errors,
                             started_at: started_at, finished_at: Time.now.utc)
        end

        def empty_batch(operation)
          now = Time.now.utc
          OperationBatch.new(operation: operation, outcomes: [], callback_errors: [], started_at: now, finished_at: now)
        end

        # 所有目标必须唯一、可执行且厂商匹配；后面的无效目标不能在前面设备已写后才发现。
        def select_devices(tasks, snapshot)
          inventory = @inventory.call(snapshot)
          raise ArgumentError, "inventory must return an Array of Devices" unless inventory.is_a?(Array) && inventory.all?(Device)

          by_host = {}
          duplicates = {}
          inventory.each do |device|
            next unless tasks.key?(device.host)

            duplicates[device.host] = true if by_host.key?(device.host)
            by_host[device.host] = device
          end
          tasks.map do |host, value|
            device = by_host[host]
            unless device&.ready? && !duplicates.key?(host)
              raise ArgumentError, "target must identify exactly one ready inventory device"
            end
            if value.is_a?(Topology::Plan)
              Topology.validate_plan!(value, host: device.host, vendor: device.vendor)
            elsif value.nil?
              Topology.validate_vendor_support!(host: device.host, vendor: device.vendor, phase: :plan)
            end
            device
          end
        end

        # 返回失败的 Result 仍携带已完成步骤；设备关闭故障也不能覆盖原操作错误。
        def perform(device, snapshot, callback_errors, on_start, on_result, &operation)
          started_at = Time.now.utc
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          notify(on_start, device, callback_errors, device.host)
          value, error = DeviceSession.call(factory: -> { build_connector(device, snapshot) }) do |connector|
            result = operation.call(connector)
            if result.is_a?(Topology::Plan) && (result.host != device.host || result.vendor != device.vendor)
              raise ArgumentError, "planned evidence does not match its inventory device"
            end
            result
          end
          error = value.error || error if value.is_a?(Result)
          status = if error.is_a?(MissingCredentials)
                     error = nil
                     :missing_credentials
                   elsif error
                     value && (!value.is_a?(Result) || value.success? || !value.steps.empty?) ? :partial : :failed
                   else
                     :succeeded
                   end
          outcome = OperationOutcome.new(device: device, status: status, value: value, error: error,
                                         started_at: started_at, finished_at: Time.now.utc,
                                         duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
          notify(on_result, outcome, callback_errors, device.host)
          outcome
        end

        def build_connector(device, snapshot)
          options = @credentials ? @credentials.call(device) : @settings.device_credentials_for(device)
          raise MissingCredentials if options.nil?

          unless options.is_a?(Hash) && options.keys.all?(Symbol) && !options.key?(:host) &&
                 options[:username].is_a?(String) && !options[:username].empty?
            raise ArgumentError, "credential resolver must return settings with username and without host"
          end
          options = snapshot.connection_options(device.vendor).merge(options)
          if snapshot.log_directory
            options[:log_file] = File.join(snapshot.log_directory, "#{device.host.tr(":", "_")}.log")
          end
          @connector_factory.call(device, options)
        end

        # 普通通知故障只保存白名单类型；中断仍由线程池回收整批设备会话。
        def notify(callback, value, errors, host)
          callback&.call(value)
        rescue StandardError => error
          errors << { host: host, error_type: Diagnostic.from(error).error_type }.freeze
        end
      end
    end
  end
end
