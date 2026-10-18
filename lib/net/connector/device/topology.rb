# frozen_string_literal: true

require_relative "topology/strategy"
require_relative "topology/stages"
require_relative "topology/plan"
require_relative "topology/audit"

module Net
  module Connector
    # 从 CDP/LLDP 回显生成链路邻居，并规划接口描述变更。
    class Topology
      # 设备入口与功能实现共置，Base 只组合能力，不重复业务流程。
      module Capability
        # 执行 CDP 或 LLDP 查询并返回统一的链路邻居记录。
        def neighbors = Topology.new(self).neighbors

        # 读取运行配置中的接口描述或端口名称。
        def interface_descriptions = Topology.new(self).interface_descriptions

        # 显式同步请求在同一会话中完成发现、修改、读回与保存，无须调用方传递计划。
        def sync_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
          Topology.new(self).sync_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
        end

        # 以邻居和现有配置为证据，生成待确认的接口描述变更计划。
        def plan_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
          Topology.new(self).plan_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
        end

        # 核实各接口，保留缺失/冲突证据并为可确认的接口构造独立计划。
        def audit_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
          Topology.new(self).audit_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
        end

        # 明确确认且现场证据未变化时执行接口描述计划。
        def apply_interface_descriptions(plan, confirmed: false)
          Topology.new(self).apply_interface_descriptions(plan, confirmed: confirmed)
        end
      end

      # 仅承载厂商档案的离线上下文，不能连接、查询或下发设备命令。
      PlanningContext = Data.define(:host, :vendor, :profile) do
        def config_commands = profile.config_commands
      end
      private_constant :PlanningContext

      # 全批应用前拒绝可离线判定的能力或命令问题；现场证据仍由单设备操作重验。
      def self.validate_plan!(plan, host:, vendor:)
        unless plan.is_a?(Plan) && plan.host == host && plan.vendor == vendor
          raise ArgumentError, "plan must match its target device"
        end
        if plan.changes.empty?
          raise ArgumentError, "empty topology plan cannot contain commands" unless plan.commands.empty?

          return plan
        end
        strategy = planning_strategy(host: host, vendor: vendor)
        validate_change_support!(strategy, host: host, phase: :apply)
        stages = Stages.build(strategy: strategy, host: host, changes: plan.changes)
        unless stages.values.flat_map { |script| script.map(&:text) } == plan.commands
          raise ArgumentError, "plan commands were modified or use an older execution sequence; regenerate the plan"
        end
        plan
      end

      # 批次规划在建立任一会话前检查整个目标集合的厂商写入能力。
      def self.validate_vendor_support!(host:, vendor:, phase:)
        validate_change_support!(planning_strategy(host: host, vendor: vendor), host: host, phase: phase)
      end

      def self.planning_strategy(host:, vendor:)
        profile = Net::Connector.vendor_class(vendor).profile
        (profile.topology_strategy || Strategy).new(PlanningContext.new(host: host, vendor: vendor, profile: profile))
      end
      private_class_method :planning_strategy

      # 能力声明不需要会话；规划、批次预检和现场应用使用同一厂商规则。
      def self.validate_change_support!(strategy, host:, phase:)
        return if strategy.supports?(:interface_description_changes)

        raise UnsupportedOperation.new("automatic interface description changes are unavailable; use a verified manual workflow",
                                       code: strategy.change_error_code, host: host, phase: phase)
      end

      # 保存设备及其独立的 TextFSM 解析入口。
      def initialize(device, template_dir: nil)
        require_relative "../textfsm"

        @device = device
        @parser = TextFSM.new(template_dir: template_dir)
        @strategy = (device.profile.topology_strategy || Strategy).new(device)
      end

      # 执行厂商 CDP/LLDP 命令，返回统一的邻居记录。
      def neighbors
        command = @strategy.neighbor_command
        unless @strategy.supports?(:neighbors) && command
          raise UnsupportedOperation.new("this device cannot discover LLDP neighbors",
                                         code: :neighbor_discovery_unsupported, host: @device.host, phase: :discover)
        end

        output = Terminal::Text.utf8(@device.execute_command(command).value!, host: @device.host)
        template = @strategy.neighbor_template(output)
        rows = @parser.call(output, template: template, vendor: @device.vendor, command: command, host: @device.host)
        if rows.size != @strategy.expected_neighbor_count(output, template) || (rows.empty? && !@strategy.empty_neighbor_output?(output))
          raise ParsingError.new("neighbor output was not recognized", code: :unrecognized_output,
                                 host: @device.host, phase: :discover)
        end

        rows.map do |row|
          Neighbor.new(local_interface: row.fetch("LOCAL_INTERFACE").strip.freeze,
                       neighbor_name: row.fetch("NEIGHBOR_NAME", "").strip.freeze,
                       neighbor_interface: row.fetch("NEIGHBOR_INTERFACE").strip.freeze,
                       chassis_id: row.fetch("CHASSIS_ID", "").strip.freeze,
                       protocol: @strategy.protocol).freeze
        end
      end

      # 从运行配置读取已设置的接口描述或端口名称。
      def interface_descriptions = read_interface_descriptions

      # 内部读取先交付执行步骤，再处理解析；解析失败也不能抹去已经完成的采集命令。
      def read_interface_descriptions
        template = @strategy.description_template
        unless @strategy.supports?(:interface_descriptions) && template
          raise UnsupportedOperation.new("interface descriptions are unsupported for this vendor",
                                         code: :description_unsupported, host: @device.host, phase: :discover)
        end
        result = @device.running_config
        yield result if block_given?
        config = result.value!
        rows = @parser.call(config, template: template, host: @device.host)
        @strategy.validate_descriptions!(config, rows)
        rows.each_with_object({}) do |row, found|
          interface = @strategy.description_key(row)
          description = @strategy.decode_description(row.fetch("DESCRIPTION", ""))
          previous = found[interface]
          if previous && !previous.empty? && !description.empty? && previous != description
            raise ParsingError.new("interface has conflicting descriptions", code: :ambiguous_description,
                                   host: @device.host, phase: :parse)
          end
          found[interface] = description unless description.empty? && previous
        end
      end

      private :read_interface_descriptions

      # 调用即表达修改意图；同一租约覆盖发现到保存，外部变更仍须重验。
      def sync_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
        unless [abbreviate, lowercase].all? { |value| value == true || value == false }
          raise ArgumentError, "description formatting options must be boolean"
        end
        validate_change_support!(:apply)
        @device.with_operation(:apply) do
          plan = plan_interface_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
          plan.changes.empty? ? Result.new : apply_plan(plan)
        end
      end

      def audit_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
        unless [abbreviate, lowercase].all? { |value| value == true || value == false }
          raise ArgumentError, "description formatting options must be boolean"
        end
        formatter ||= ->(peer) { InterfaceDescription.format(peer, abbreviate: abbreviate, lowercase: lowercase) }
        @device.with_operation(:plan) do
          AuditBuilder.new(host: @device.host, vendor: @device.vendor, strategy: @strategy,
                           neighbors: neighbors, descriptions: interface_descriptions, formatter: formatter).call
        end
      end

      # 比对邻居和现有描述，生成包含确切命令的只读变更计划。
      def plan_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
        validate_change_support!(:plan) if @strategy.supports?(:neighbors)
        discovered = neighbors
        current = interface_descriptions
        evidence = evidence_for(discovered, current)
        changes = discovered.filter_map do |neighbor|
          old = current.fetch(@strategy.interface_key(neighbor.local_interface))
          proposed = if formatter
                       formatter.call(neighbor)
                     else
                       InterfaceDescription.format(neighbor, abbreviate: abbreviate, lowercase: lowercase)
                     end
          InterfaceDescription.validate!(proposed)
          next if old == proposed

          Change.new(interface: @strategy.configuration_interface(neighbor.local_interface), old_description: old,
                     new_description: proposed, neighbor: neighbor)
        end.freeze
        commands = if changes.empty?
                     []
                   else
                     stage_scripts(changes).values.flat_map { |script| script.map(&:text) }
                   end
        Plan.new(host: @device.host, vendor: @device.vendor, evidence: evidence,
                 changes: changes, commands: commands)
      end

      # 只有明确确认且邻居和旧描述未变化时，才下发计划中的命令。
      def apply_interface_descriptions(plan, confirmed: false)
        unless confirmed == true
          raise UnsupportedOperation.new("description plan requires confirmation", code: :confirmation_required,
                                         host: @device.host, phase: :apply)
        end
        raise ArgumentError, "plan must be a topology plan for this device" unless plan.is_a?(Plan) &&
                                                                                   plan.host == @device.host &&
                                                                                   plan.vendor == @device.vendor
        if plan.changes.empty?
          raise ArgumentError, "empty topology plan cannot contain commands" unless plan.commands.empty?

          return Result.new
        end

        @strategy.supports?(:neighbors) ? validate_change_support!(:apply) : neighbors
        @device.with_operation(:apply) { apply_plan(plan) }
      end

      private

      # 同一租约覆盖重验、修改、读回与保存；有完成步骤后发生的错误必须带回这些步骤。
      def apply_plan(plan)
        stages = stage_scripts(plan.changes)
        unless stages.values.flat_map { |script| script.map(&:text) } == plan.commands
          raise ArgumentError, "plan commands were modified or use an older execution sequence; regenerate the plan"
        end
        revalidate_plan!(plan)
        steps = []
        result = execute_stage(stages.fetch(:change), steps)
        return Result.new(steps: steps, error: result.error) if result.failure?

        verify_descriptions!(plan.changes, stages.fetch(:verify), steps)
        persisting = true
        result = execute_stage(stages.fetch(:persist), steps)
        if result.failure? || !@strategy.persistence_confirmed?(result)
          return Result.new(steps: steps, error: build_persistence_error(result.error))
        end
        Result.new(steps: steps)
      rescue Error => error
        raise unless steps

        Result.new(steps: steps, error: persisting ? build_persistence_error(error) : error)
      end

      # 读回命令与审批一致，并且每个目标描述均得到确认，才允许进入保存阶段。
      def verify_descriptions!(changes, script, steps)
        unless Script.new(@device.config_commands).map(&:text) == script.map(&:text)
          raise DeviceError.new("configuration readback commands changed after approval",
                                code: :verification_plan_changed, host: @device.host, phase: :verify)
        end
        updated = read_interface_descriptions do |readback|
          steps.concat(readback.steps)
          if readback.success? && readback.steps.map { |step| step.command.text } != script.map(&:text)
            raise DeviceError.new("configuration readback did not execute the approved commands",
                                  code: :verification_plan_changed, host: @device.host, phase: :verify)
          end
        end
        return if changes.all? { |change| updated[@strategy.interface_key(change.interface)] == change.new_description }

        raise DeviceError.new("interface descriptions were not confirmed by readback",
                              code: :description_unconfirmed, host: @device.host, phase: :verify)
      end

      # 重验失败仍在写入前直接抛异常，保持 stale_plan 的既有契约。
      def revalidate_plan!(plan)
        discovered = neighbors
        current = interface_descriptions
        if plan.scope == :interfaces
          discovered = discovered.select { |neighbor| plan.evidence.key?(@strategy.interface_key(neighbor.local_interface)) }
          current = current.slice(*plan.evidence.keys)
        end
        evidence = evidence_for(discovered, current)
        current_neighbors = discovered.to_h { |neighbor| [@strategy.interface_key(neighbor.local_interface), neighbor] }
        same_neighbors = plan.changes.all? do |change|
          current_neighbors[@strategy.interface_key(change.interface)] == change.neighbor
        end
        unless evidence == plan.evidence && same_neighbors
          raise DeviceError.new("neighbors or interface descriptions changed after planning",
                                code: :stale_plan, host: @device.host, phase: :apply)
        end

        plan.changes.each do |change|
          InterfaceDescription.validate!(change.new_description)
          unless evidence.fetch(@strategy.interface_key(change.interface)) ==
                 [change.neighbor.neighbor_name, change.neighbor.neighbor_interface, change.old_description]
            raise ArgumentError, "plan changes do not match its discovery evidence"
          end
        end
      end

      # 审批列表保留真正执行的读回命令，使旧版“先保存后读回”计划无法静默复用。
      def stage_scripts(changes)
        Stages.build(strategy: @strategy, host: @device.host, changes: changes)
      end

      def execute_stage(script, steps)
        result = @device.execute_script(script)
        steps.concat(result.steps)
        result
      end

      # 保存可能已执行，超时、失败或缺少完成行均不自动重放；诊断不附带回显正文。
      def build_persistence_error(error = nil)
        underlying = UnderlyingError.new(error, nil, sensitive: true) if error
        DeviceError.new("interface descriptions were verified; persistence was not confirmed",
                        code: :persistence_unconfirmed, host: @device.host, phase: :persist, underlying: underlying)
      end

      # 下发描述前确认厂商提供配置能力，避免把只读发现当成可写能力。
      def validate_change_support!(phase)
        self.class.validate_change_support!(@strategy, host: @device.host, phase: phase)
      end

      # 汇总邻居身份和当前描述，并要求每个目标接口都有配置证据。
      def evidence_for(discovered, current)
        interfaces = discovered.group_by { |neighbor| @strategy.interface_key(neighbor.local_interface) }
        if interfaces.any? { |_interface, peers| peers.size != 1 || peers.first.neighbor_name.empty? ||
          peers.first.neighbor_interface.empty? }
          raise ParsingError.new("neighbor identity is incomplete or ambiguous", code: :ambiguous_neighbor,
                                 host: @device.host, phase: :plan)
        end
        unless interfaces.keys.all? { |interface| current.key?(interface) }
          raise ParsingError.new("neighbor interface was not found in running configuration",
                                 code: :interface_missing, host: @device.host, phase: :plan)
        end

        interfaces.transform_values do |peers|
          peer = peers.fetch(0)
          [peer.neighbor_name, peer.neighbor_interface, current.fetch(@strategy.interface_key(peer.local_interface))].freeze
        end.freeze
      end


    end
  end
end
