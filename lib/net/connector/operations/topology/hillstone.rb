# frozen_string_literal: true

require_relative "../../vendor/hillstone/topology"

module Net
  module Connector
    module Operations
      Topology::Hillstone = Net::Connector::Hillstone::Topology
    end
  end
end
