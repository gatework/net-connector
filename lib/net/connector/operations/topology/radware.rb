# frozen_string_literal: true

require_relative "../../vendor/radware/topology"

module Net
  module Connector
    module Operations
      Topology::Radware = Net::Connector::Radware::Topology
    end
  end
end
