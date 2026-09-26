# frozen_string_literal: true

require_relative "../device/running_config"

module Net
  module Connector
    module Operations
      # 旧常量与新能力共享同一实现，不维护第二套采集流程。
      RunningConfig = Net::Connector::RunningConfig
      RunningConfig.autoload :Cisco, File.expand_path("running_config/cisco", __dir__)
      RunningConfig.autoload :CiscoNxos, File.expand_path("running_config/cisco", __dir__)
      RunningConfig.autoload :Hillstone, File.expand_path("running_config/hillstone", __dir__)
      RunningConfig.autoload :PaloAlto, File.expand_path("running_config/palo_alto", __dir__)
    end
  end
end
