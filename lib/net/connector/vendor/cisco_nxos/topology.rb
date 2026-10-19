# frozen_string_literal: true

require_relative "../cisco"

module Net
  module Connector
    module Vendor
      class CiscoNxos < Cisco
        # NX-OS 使用独立输出模板；配置下发、读回及保存阶段继续复用 Cisco 协议。
        class Topology < Cisco::Topology
          # 选择 NX-OS CDP 邻居详情模板。
          def neighbor_template(_output) = "cisco_nxos/show_cdp_neighbors_detail.textfsm"

          # 选择 NX-OS 运行配置中的接口描述模板。
          def description_template = "cisco_nxos/show_running_config.textfsm"

          # 从设备声明的总数或详情条目推导预期邻居数，用于完整性核对。
          def expected_neighbor_count(output, _template)
            output.scan(/^\s*Device[ -]ID:/i).size
          end
        end
      end
    end
  end
end
