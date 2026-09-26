# frozen_string_literal: true

require_relative "../running_config"
require_relative "../../vendor/hillstone/running_config"

module Net
  module Connector
    module Operations
      RunningConfig::Hillstone = Net::Connector::Hillstone::RunningConfig
    end
  end
end
