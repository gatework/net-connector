# frozen_string_literal: true

require_relative "../device/base"
require_relative "cisco/running_config"
require_relative "cisco/topology"

module Net
  module Connector
    module Vendor
      # IOS 与 NX-OS 共用的运行配置、CDP 拓扑和复制确认协议；具体平台声明视图与诊断差异。
      class Cisco < Net::Connector::Base
        profile do
          running_config_strategy RunningConfig
          topology_strategy Topology
          commands { running_config "terminal length 0", "show running-config" }
          command_timeout 60
          interactions do
            confirm(/Destination\s+filename\s+\[[^\]]+\]\?\s*\z/i, response: "\n")
            confirm(%r{Do\s+you\s+want\s+to\s+overwrite\?\s*\[yes/no\]\s*\z}i, response: "yes\n")
          end
        end
      end
    end
  end
end
