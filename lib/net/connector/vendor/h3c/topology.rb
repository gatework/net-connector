# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module H3c
      class Topology < Operations::Topology::Strategy
        TABLE_HEADER = /^\s*(?:System Name\s+Local Interface\b|(?:Local Interface|LocalIf)\s+)/i
        def self.supports?(capability)
          %i[neighbors interface_descriptions interface_description_changes].include?(capability)
        end

        def neighbor_command = "display lldp neighbor-information list"
        def description_template = "h3c_interface_descriptions.textfsm"
        def enter_configuration = "system-view"
        def finish_commands = ["return"] + @device.profile.save_commands

        def neighbor_template(output)
          return "h3c_lldp_name_first.textfsm" if output.match?(/^\s*System Name\s+Local Interface\b/im)
          return "h3c_lldp_local_first.textfsm" if output.match?(/^\s*(?:Local Interface|LocalIf)\s+/im)

          raise ParsingError.new("H3C LLDP table header was not recognized", code: :unrecognized_output,
                                 host: @device.host, phase: :discover)
        end

        def expected_neighbor_count(output, template)
          local_column = template == "h3c_lldp_name_first.textfsm" ? 1 : 0
          lines = neighbor_lines(output)
          return unless lines.all? do |line|
            interface = line.split.fetch(local_column, nil)
            interface&.match?(/\A[A-Za-z][A-Za-z-]*\d+(?:\/\d+)+\z/)
          end

          lines.size
        end

        # 表头之后的未知行不能作为零邻居证据。
        def empty_neighbor_output?(output) = neighbor_lines(output).empty?

        def change_commands(change)
          InterfaceDescription.commands(interface: change.interface, description: change.new_description, leave: "quit")
        end

        private

        def neighbor_lines(output)
          output.lines.drop_while { |line| !line.match?(TABLE_HEADER) }.map(&:strip).reject do |line|
            line.empty? || line.match?(TABLE_HEADER) || line.match?(/\A[-=+ ]+\z/) ||
              line.match?(/\A(?:<[^>]+>|\[[^\]]+\])\z/)
          end
        end
      end
    end
  end
end
