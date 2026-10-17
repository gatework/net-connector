# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/topology/strategy"

module Net
  module Connector
    module Vendor
      class Radware < Net::Connector::Base
        # 只读取 Alteon 端口名称，不声明邻居发现或描述改写能力。
        class Topology < Net::Connector::Topology::Strategy
          # Alteon 只支持读取端口描述，不提供邻居发现或自动改写。
          def self.supports?(capability) = capability == :interface_descriptions

          # 从设备配置转储解析端口名称。
          def description_template = "radware/cfg_dump.textfsm"
        end
      end
    end
  end
end
