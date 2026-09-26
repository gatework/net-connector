# frozen_string_literal: true

require_relative "../running_config"
require_relative "../../vendor/cisco_ios/running_config"
require_relative "../../vendor/cisco_nxos/running_config"

module Net
  module Connector
    module Operations
      RunningConfig::Cisco = Net::Connector::CiscoIos::RunningConfig
      RunningConfig::CiscoNxos = Net::Connector::CiscoNxos::RunningConfig
    end
  end
end
