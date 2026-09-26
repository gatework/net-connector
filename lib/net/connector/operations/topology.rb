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

          output = @device.execute(command).value!
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
        def descriptions
          template = @strategy.description_template
          unless @strategy.supports?(:interface_descriptions) && template
            raise UnsupportedOperation.new("interface descriptions are unsupported for this vendor",
                                           code: :description_unsupported, host: @device.host, phase: :discover)
          end
          config = @device.running_config.value!
          @parser.call(config, template: template, host: @device.host).each_with_object({}) do |row, found|
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
                       [@strategy.enter_configuration] + changes.flat_map { |change| change_commands(change) } + @strategy.finish_commands
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
          return Result.new if plan.changes.empty?

          check_change_support!(:apply) if @strategy.supports?(:neighbors)
          @device.with_operation(:apply) { apply_plan(plan) }
        end

        private

        # 现场复核、修改和回读属于同一次独占操作。
        def apply_plan(plan)
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
          commands = [@strategy.enter_configuration] + plan.changes.flat_map { |change| change_commands(change) } + @strategy.finish_commands
          raise ArgumentError, "plan commands were modified" unless commands == plan.commands

          script = commands.map do |command|
            @strategy.script_command(command)
          end
          result = @device.execute_script(Script.new(script, name: "interface descriptions"))
          return result if result.failure?

          updated = descriptions
          return result if plan.changes.all? do |change|
            updated.fetch(@strategy.interface_key(change.interface), "") == change.new_description
          end

          Result.new(steps: result.steps,
                     error: DeviceError.new("interface descriptions were not confirmed by readback",
                                            code: :description_unconfirmed, host: @device.host, phase: :verify))
        rescue Error => error
          raise unless result&.success?

          Result.new(steps: result.steps, error: error)
        end

        # 下发描述前确认厂商提供配置能力，避免把只读发现当成可写能力。
        def check_change_support!(phase)
          return if @strategy.supports?(:interface_description_changes)

          raise UnsupportedOperation.new("interface description changes are unsupported for this vendor",
                                         code: :description_unsupported, host: @device.host, phase: phase)
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
