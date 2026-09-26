# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module Radware
      class Topology < Operations::Topology::Strategy
        def self.supports?(capability) = capability == :interface_descriptions
        def description_template = "radware_port_names.textfsm"
      end
    end
  end
end
