# frozen_string_literal: true

require_relative "../../vendor/cisco_ios/topology"

module Net
  module Connector
    module Operations
      Topology::Cisco = Net::Connector::CiscoIos::Topology
    end
  end
end
