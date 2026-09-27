# frozen_string_literal: true

require_relative "../../device/topology/strategy"

module Net
  module Connector
    module Radware
      class Topology < Topology::Strategy
        # Alteon 只支持读取端口描述，不提供邻居发现或自动改写。
        def self.supports?(capability) = capability == :interface_descriptions

        # 从设备配置转储解析端口名称。
        def description_template = "radware_port_names.textfsm"
      end
    end
  end
end
