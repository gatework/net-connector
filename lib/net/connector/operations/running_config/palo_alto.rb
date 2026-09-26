# frozen_string_literal: true

require_relative "../running_config"
require_relative "../../vendor/palo_alto/running_config"

module Net
  module Connector
    module Operations
      RunningConfig::PaloAlto = Net::Connector::PaloAlto::RunningConfig
    end
  end
end
