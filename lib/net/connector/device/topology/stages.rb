# frozen_string_literal: true

require_relative "../../engine/script"
require_relative "interface_description"

module Net
  module Connector
    class Topology
      # 离线预检与现场执行共用确切阶段，不复制厂商命令或把保存合并到变更阶段。
      module Stages
        # 分别构造变更、读回和保存脚本，拒绝没有完整阶段声明的厂商策略。
        def self.build(strategy:, host:, changes:)
          validate_changes!(strategy, changes)
          phases = %i[leave_configuration_commands verification_commands persistence_commands].map do |method|
            strategy.public_send(method)
          end
          unless phases.all? { |commands| commands.is_a?(Array) && !commands.empty? }
            raise UnsupportedOperation.new("topology strategy must declare separate readback and persistence stages",
                                           code: :description_stages_unsupported, host: host, phase: :plan)
          end
          leave, verify, persist = phases
          commands = changes.flat_map do |change|
            strategy.change_commands(change)
          end
          sequences = { change: [strategy.enter_configuration_command] + commands + leave,
                        verify: verify, persist: persist }
          sequences.transform_values do |sequence|
            Script.new(sequence.map { |command| strategy.script_command(command) }, name: "interface descriptions")
          end
        end

        # 同一物理接口只能出现一次；缩写与全称也不能绕过离线和现场的共同预检。
        def self.validate_changes!(strategy, changes)
          unless changes.is_a?(Array) && changes.all?(Topology::Change)
            raise ArgumentError, "topology changes must be an Array of Changes"
          end

          interfaces = {}
          changes.each do |change|
            InterfaceDescription.validate_interface!(change.interface)
            key = strategy.interface_key(change.interface)
            raise ArgumentError, "topology changes must identify unique interfaces" if interfaces.key?(key)

            interfaces[key] = true
          end
        end
        private_class_method :validate_changes!
      end
    end
  end
end
