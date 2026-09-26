# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module Hillstone
      class Topology < Operations::Topology::Strategy
        def self.supports?(capability)
          %i[neighbors interface_descriptions interface_description_changes].include?(capability)
        end

        def neighbor_command = "show lldp neighbor-information"
        def description_template = "hillstone_interface_descriptions.textfsm"
        def enter_configuration = "configure"
        def finish_commands = ["exit"] + @device.profile.save_commands

        def expected_neighbor_count(output, _template)
          reported = output[/Total lldp neighbor number:\s*(\d+)/i, 1]
          lines = neighbor_lines(output)
          return unless lines.all? { |line| line.match?(/\A\S+\s+ethernet\d+\/\d+\s/i) }
          return if reported && reported.to_i != lines.size

          lines.size
        end

        def empty_neighbor_output?(output)
          neighbor_lines(output).empty? && (output.match?(/Total lldp neighbor number:\s*0\b/i) ||
            output.match?(/System Name\s+Local Interface/i))
        end

        def change_commands(change)
          InterfaceDescription.commands(interface: change.interface, description: change.new_description)
        end

        private

        def neighbor_lines(output)
          output.lines.map(&:strip).reject do |line|
            line.empty? || line == neighbor_command || line.match?(/\ASystem Name\s+Local Interface\b/i) ||
              line.match?(/\ATotal lldp neighbor number:\s*\d+\.?\z/i) ||
              line.match?(/\A[-=+ ]+\z/) || line.match?(/\A\S+(?:#|\([MBF]\))\z/)
          end
        end
      end
    end
  end
end
