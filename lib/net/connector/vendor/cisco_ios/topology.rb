# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module CiscoIos
      class Topology < Operations::Topology::Strategy
        def self.supports?(capability)
          %i[neighbors interface_descriptions interface_description_changes].include?(capability)
        end

        def neighbor_command = "show cdp neighbors detail"
        def description_template = "cisco_ios_running_config_interfaces.textfsm"
        def protocol = :cdp
        def enter_configuration = "configure terminal"
        def finish_commands = ["end"] + @device.profile.save_commands

        def expected_neighbor_count(output, _template)
          output.scan(/^\s*Device ID:\s*\S+/i).size
        end

        def empty_neighbor_output?(output)
          output.match?(/Total cdp entries displayed\s*:\s*0|no cdp neighbors/i)
        end

        def change_commands(change)
          InterfaceDescription.commands(interface: change.interface, description: change.new_description)
        end
      end
    end
  end
end
