# frozen_string_literal: true

require_relative "topology/strategy"

module Net
  module Connector
    module Operations
      # 从 CDP/LLDP 回显生成链路邻居，并规划接口描述变更。
      class Topology
        Neighbor = Data.define(:local_interface, :neighbor_name, :neighbor_interface, :chassis_id, :protocol)
        Change = Data.define(:interface, :old_description, :new_description, :neighbor)
        Plan = Data.define(:host, :vendor, :evidence, :changes, :commands)

        # 保存设备及其独立的 TextFSM 解析入口。
        def initialize(device, template_dir: nil)
          require_relative "parse_output"

          @device = device
          @parser = ParseOutput.new(template_dir: template_dir)
          @strategy = (device.profile.topology_strategy || Strategy).new(device)
        end

        # 执行厂商 CDP/LLDP 命令，返回统一的邻居记录。
        def neighbors
          command = @strategy.neighbor_command
          unless @strategy.supports?(:neighbors) && command
            raise UnsupportedOperation.new("this device cannot discover LLDP neighbors",
                                           code: :neighbor_discovery_unsupported, host: @device.host, phase: :discover)
          end

          output = @parser.utf8(@device.execute(command).value!, host: @device.host)
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
        def descriptions = read_descriptions

        # 内部读取先交付执行步骤，再处理解析；解析失败也不能抹去已经完成的采集命令。
        def read_descriptions
          template = @strategy.description_template
          unless @strategy.supports?(:interface_descriptions) && template
            raise UnsupportedOperation.new("interface descriptions are unsupported for this vendor",
                                           code: :description_unsupported, host: @device.host, phase: :discover)
          end
          result = @device.running_config
          yield result if block_given?
          config = result.value!
          rows = @parser.call(config, template: template, host: @device.host)
          @strategy.validate_descriptions!(config, rows) if @strategy.respond_to?(:validate_descriptions!)
          rows.each_with_object({}) do |row, found|
            interface = @strategy.interface_key(row.fetch("INTERFACE"))
            description = @strategy.decode_description(row.fetch("DESCRIPTION", ""))
            previous = found[interface]
            if previous && !previous.empty? && !description.empty? && previous != description
              raise ParsingError.new("interface has conflicting descriptions", code: :ambiguous_description,
                                     host: @device.host, phase: :parse)
            end
            found[interface] = description unless description.empty? && previous
          end
        end

        private :read_descriptions

        # 比对邻居和现有描述，生成包含确切命令的只读变更计划。
        def plan_descriptions(abbreviate: true, lowercase: false, &formatter)
          check_change_support!(:plan) if @strategy.supports?(:neighbors)
          discovered = neighbors
          current = descriptions
          current.each_value(&:freeze)
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

            Change.new(interface: @strategy.configuration_interface(neighbor.local_interface).freeze, old_description: old.freeze,
                       new_description: proposed.freeze, neighbor: neighbor).freeze
          end.freeze
          commands = if changes.empty?
                       []
                     else
                       stage_scripts(changes).values.flat_map { |script| script.map(&:text) }
                     end
          commands.each(&:freeze)
          Plan.new(host: @device.host.dup.freeze, vendor: @device.vendor, evidence: evidence,
                   changes: changes, commands: commands.freeze).freeze
        end

        # 只有明确确认且邻居和旧描述未变化时，才下发计划中的命令。
        def apply(plan, confirmed: false)
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

          @strategy.supports?(:neighbors) ? check_change_support!(:apply) : neighbors
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
            return Result.new(steps: steps, error: persistence_error(result.error))
          end
          Result.new(steps: steps)
        rescue Error => error
          raise unless steps

          Result.new(steps: steps, error: persisting ? persistence_error(error) : error)
        end

        # 读回命令与审批一致，并且每个目标描述均得到确认，才允许进入保存阶段。
        def verify_descriptions!(changes, script, steps)
          unless Script.new(@device.config_commands).map(&:text) == script.map(&:text)
            raise DeviceError.new("configuration readback commands changed after approval",
                                  code: :verification_plan_changed, host: @device.host, phase: :verify)
          end
          updated = read_descriptions do |readback|
            steps.concat(readback.steps)
            if readback.success? && readback.steps.map { |step| step.command.text } != script.map(&:text)
              raise DeviceError.new("configuration readback did not execute the approved commands",
                                    code: :verification_plan_changed, host: @device.host, phase: :verify)
            end
          end
          unless changes.all? { |change| updated[@strategy.interface_key(change.interface)] == change.new_description }
            raise DeviceError.new("interface descriptions were not confirmed by readback",
                                  code: :description_unconfirmed, host: @device.host, phase: :verify)
          end
        end

        # 重验失败仍在写入前直接抛异常，保持 stale_plan 的既有契约。
        def revalidate_plan!(plan)
          discovered = neighbors
          evidence = evidence_for(discovered, descriptions)
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
          phases = %i[leave_configuration verification_commands persistence_commands].map do |method|
            @strategy.public_send(method) if @strategy.respond_to?(method)
          end
          unless phases.all? { |commands| commands.is_a?(Array) && !commands.empty? }
            raise UnsupportedOperation.new("topology strategy must declare separate readback and persistence stages",
                                           code: :description_stages_unsupported, host: @device.host, phase: :plan)
          end
          leave, verify, persist = phases
          sequences = {
            change: [@strategy.enter_configuration] + changes.flat_map { |change| change_commands(change) } + leave,
            verify: verify, persist: persist
          }
          sequences.transform_values do |commands|
            Script.new(commands.map { |command| @strategy.script_command(command) }, name: "interface descriptions")
          end
        end

        def execute_stage(script, steps)
          result = @device.execute_script(script)
          steps.concat(result.steps)
          result
        end

        # 保存可能已执行，超时、失败或缺少完成行均不自动重放；诊断不附带回显正文。
        def persistence_error(error = nil)
          underlying = UnderlyingError.new(error, nil, sensitive: true) if error
          DeviceError.new("interface descriptions were verified; persistence was not confirmed",
                          code: :persistence_unconfirmed, host: @device.host, phase: :persist, underlying: underlying)
        end

        # 下发描述前确认厂商提供配置能力，避免把只读发现当成可写能力。
        def check_change_support!(phase)
          return if @strategy.supports?(:interface_description_changes)

          code = @strategy.respond_to?(:change_error_code) ? @strategy.change_error_code : :description_unsupported
          raise UnsupportedOperation.new("automatic interface description changes are unavailable; use a verified manual workflow",
                                         code: code, host: @device.host, phase: phase)
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

        # 设备标识来自解析证据，仍需在生成命令前验证其安全性。
        def change_commands(change)
          InterfaceDescription.validate_interface!(change.interface)
          @strategy.change_commands(change)
        end
      end
    end
  end
end
