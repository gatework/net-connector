# frozen_string_literal: true

require "ipaddr"
require "time"
require "fileutils"
require_relative "../parallel/pool"
require_relative "../device/scope"
require_relative "../device/topology"
require_relative "settings"
require_relative "operations/batch"
require_relative "device/access"
require_relative "resources"

module Net
  module Connector
    module Netdisco
      # 配置执行与接口修正共用设备生命周期，各业务仍保留自己的审批和结果。
      class Operations
        DEFAULT_SETTING = Object.new.freeze
        MissingCredentials = Class.new(StandardError)
        private_constant :DEFAULT_SETTING, :MissingCredentials

        # 绑定策略、清单和逐设备接入依赖，校验工厂与回调入口。
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
        def execute_scripts(scripts:, confirmed: false, parallel: DEFAULT_SETTING, on_start: nil, on_result: nil)
          validate_confirmation!(confirmed)
          tasks = normalize_mapping(scripts, :scripts) do |script|
            script.is_a?(String) ? Script.parse(script) : (script.is_a?(Script) ? script : Script.new(script))
          end
          run(:execute_scripts, tasks, parallel: parallel, on_start: on_start, on_result: on_result) do |connector, script|
            result = connector.execute_script(script)
            raise TypeError, "configuration operation must return a Result" unless result.is_a?(Result)

            result
          end
        end

        # 一次调用完成邻居发现与描述同步；每台设备独占会话，普通失败互不影响。
        def sync_interface_descriptions(hosts:, abbreviate: true, lowercase: false, parallel: DEFAULT_SETTING,
                                        on_start: nil, on_result: nil, &formatter)
          tasks = description_targets(hosts, abbreviate, lowercase)
          run(:sync_interface_descriptions, tasks, parallel: parallel, on_start: on_start, on_result: on_result) do |connector, _|
            result = connector.sync_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
            raise TypeError, "description synchronization must return a Result" unless result.is_a?(Result)

            result
          end
        end

        # 规划只读取现场证据；格式化回调并发执行，不承担设备连接或审批职责。
        def plan_interface_descriptions(hosts:, abbreviate: true, lowercase: false, parallel: DEFAULT_SETTING,
                                        on_start: nil, on_result: nil, &formatter)
          tasks = description_targets(hosts, abbreviate, lowercase)

          run(:plan_interface_descriptions, tasks, parallel: parallel, on_start: on_start, on_result: on_result) do |connector, _|
            result = connector.plan_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
            raise TypeError, "description planning must return a Net::Connector::Topology::Plan" unless result.is_a?(Net::Connector::Topology::Plan)

            normalize_plan(result)
          end
        end

        # 审批计划固定并验证；单设备应用仍执行现场重验、读回和保存，不直接重放 commands。
        def apply_interface_descriptions(plans:, confirmed: false, parallel: DEFAULT_SETTING, on_start: nil, on_result: nil)
          validate_confirmation!(confirmed)
          tasks = normalize_mapping(plans, :plans) { |plan| normalize_plan(plan) }
          tasks.each do |host, plan|
            raise ArgumentError, "plan host does not match its target" unless normalize_host(plan.host) == host
          end
          run(:apply_interface_descriptions, tasks, parallel: parallel, on_start: on_start, on_result: on_result) do |connector, plan|
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

        # 只有显式确认才允许执行配置写操作。
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

        # 规范化全批主机键并拒绝重复，在设备访问前固定各目标输入。
        def normalize_mapping(mapping, name)
          raise ArgumentError, "#{name} must be a Hash" unless mapping.is_a?(Hash)

          mapping.each_with_object({}) do |(host, value), tasks|
            host = normalize_host(host)
            raise ArgumentError, "targets must be unique" if tasks.key?(host)

            tasks[host] = block_given? ? yield(value) : value
          end.freeze
        end

        # 计划自身拥有不可变审批树；这里仅处理批次的地址和输入预检。
        def normalize_plan(plan)
          raise ArgumentError, "plans must contain Net::Connector::Topology::Plan values" unless plan.instance_of?(Net::Connector::Topology::Plan)
          host = normalize_host(plan.host)
          raise ArgumentError, "description plan contains an unsupported vendor" unless Net::Connector.vendors.include?(plan.vendor)

          Script.new(plan.commands)
          plan.changes.each do |change|
            Net::Connector::Topology::InterfaceDescription.validate_interface!(change.interface)
            Net::Connector::Topology::InterfaceDescription.validate!(change.new_description)
          end
          raise ArgumentError, "empty description plan cannot contain commands" if plan.changes.empty? && !plan.commands.empty?

          host == plan.host ? plan : plan.with(host: host)
        end

        # 策略只固定一次；清单与连接使用同一快照，凭据仍在每台任务开始时动态读取。
        def run(operation, tasks, parallel:, on_start:, on_result:)
          [on_start, on_result].each do |callback|
            raise ArgumentError, "callbacks must respond to call" unless callback.nil? || callback.respond_to?(:call)
          end
          Parallel::Pool.validate_parallel!(parallel) unless parallel.equal?(DEFAULT_SETTING)
          snapshot = @settings.snapshot(mode: :inventory)
          parallel = snapshot.parallel if parallel.equal?(DEFAULT_SETTING)
          Parallel::Pool.validate_parallel!(parallel)
          return empty_batch(operation) if tasks.empty?

          devices = select_devices(tasks, snapshot)
          Resources.prepare!(parallel: [parallel, devices.size].min)
          FileUtils.mkdir_p(snapshot.log_directory, mode: 0o700) if snapshot.log_directory
          started_at = Time.now.utc
          callback_errors = Queue.new
          outcomes = Parallel::Pool.new(parallel: parallel).map(devices) do |device|
            perform(device, snapshot, callback_errors, on_start, on_result) { |connector| yield connector, tasks.fetch(device.host) }
          end
          errors = Array.new(callback_errors.size) { callback_errors.pop }
          Operations::Batch.new(operation: operation, outcomes: outcomes, callback_errors: errors,
                             started_at: started_at, finished_at: Time.now.utc)
        end

        # 生成不读取清单、不建立连接的空操作批次。
        def empty_batch(operation)
          now = Time.now.utc
          Operations::Batch.new(operation: operation, outcomes: [], callback_errors: [], started_at: now, finished_at: now)
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
            if value.is_a?(Net::Connector::Topology::Plan)
              Net::Connector::Topology.validate_plan!(value, host: device.host, vendor: device.vendor)
            elsif value.nil?
              Net::Connector::Topology.validate_vendor_support!(host: device.host, vendor: device.vendor, phase: :plan)
            end
            device
          end
        end

        # 返回失败的 Result 仍携带已完成步骤；设备关闭故障也不能覆盖原操作错误。
        def perform(device, snapshot, callback_errors, on_start, on_result, &operation)
          started_at = Time.now.utc
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          notify(on_start, device, callback_errors, device.host)
          value, error = Net::Connector::Device::Scope.call(factory: -> { build_connector(device, snapshot) }) do |connector|
            result = operation.call(connector)
            if result.is_a?(Net::Connector::Topology::Plan) && (result.host != device.host || result.vendor != device.vendor)
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
          outcome = Operations::Outcome.new(device: device, status: status, value: value, error: error,
                                         started_at: started_at, finished_at: Time.now.utc,
                                         duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
          notify(on_result, outcome, callback_errors, device.host)
          outcome
        end

        # 按固定策略读取设备凭据，缺失时拒绝任务，否则调用连接器工厂。
        def build_connector(device, snapshot)
          options = Device::Access.resolve(device, settings: @settings, credentials: @credentials,
                                                policy: snapshot, log_directory: snapshot.log_directory)
          raise MissingCredentials if options.nil?
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
