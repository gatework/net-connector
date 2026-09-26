# frozen_string_literal: true

require_relative "../../vendor/palo_alto/topology"

module Net
  module Connector
    module Operations
      Topology::PaloAlto = Net::Connector::PaloAlto::Topology
    end
  end
end
