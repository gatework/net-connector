# frozen_string_literal: true

require_relative "../../vendor/h3c/topology"

module Net
  module Connector
    module Operations
      Topology::H3c = Net::Connector::H3c::Topology
    end
  end
end
