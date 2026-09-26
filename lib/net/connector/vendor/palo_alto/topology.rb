# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module PaloAlto
      class Topology < Operations::Topology::Strategy
        def self.supports?(capability)
          %i[neighbors interface_descriptions interface_description_changes].include?(capability)
        end

        def neighbor_command = "show lldp neighbors all"
        def description_template = "palo_alto_interface_descriptions.textfsm"
        def enter_configuration = "configure"
        def finish_commands = ["commit", "exit"]

        def expected_neighbor_count(output, _template)
          neighbor_blocks(output).count { |block| !empty_neighbor_block?(block) }
        end

        def empty_neighbor_output?(output)
          return true if output.match?(/No LLDP neighbors/i)

          blocks = neighbor_blocks(output)
          !blocks.empty? && blocks.all? { |block| empty_neighbor_block?(block) }
        end

        private

        # PAN-OS 会列出启用 LLDP、但没有邻居的本机接口；只有明确为空的
        # Neighbor information 块可跳过，缺字段的非空块继续交给数量校验拒绝。
        def neighbor_blocks(output)
          output.split(/^\s*Local information:\s*$/i).select { |block| block.match?(/^\s*Local interface:\s*\S+/i) }
        end

        def empty_neighbor_block?(block)
          tail = block.split(/^\s*Neighbor information:\s*$/i, 2)
          tail.size == 2 && tail.last.lines.all? { |line| line.strip.empty? || line.match?(/^\S+[>#]\s*$/) }
        end

        public

        # 模板按行读取；未闭合的引号表示证据不完整，不能把首行当成旧描述。
        def decode_description(value)
          value = value.strip
          value.start_with?('"') ? Shellwords.split(value).join(" ") : value
        rescue ArgumentError
          raise ParsingError.new("PAN-OS interface comment is not a complete single-line value",
                                 code: :unrecognized_output, host: @device.host, phase: :parse)
        end

        def change_commands(change)
          [%Q(set network interface ethernet #{change.interface} comment "#{change.new_description}")]
        end

        def script_command(command)
          command == "commit" ? Command.new(command, timeout: 300) : command
        end
      end
    end
  end
end
