# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/interfaces/immediate_strategy"

module Net
  module Connector
    module Vendor
      class Cisco < Net::Connector::Base
        # 基于 CDP 证据规划接口描述，变更后读回确认，再执行独立保存阶段。
        class Topology < Net::Connector::Interfaces::ImmediateStrategy
          # IOS 提供 CDP 邻居、配置描述读取和描述变更。
          def self.supports?(capability)
            %i[neighbors interface_descriptions interface_description_changes].include?(capability)
          end

          # 使用详细 CDP 输出获取对端设备与端口。
          def neighbor_command = "show cdp neighbors detail"

          # 从运行配置解析接口描述。
          def description_template = "cisco/show_running_config.textfsm"

          # 标记发现协议，供邻居记录使用。
          def protocol = :cdp

          # 进入全局配置视图。
          def enter_configuration_command = "configure terminal"

          # 先回到执行视图读回，随后才执行档案中的保存命令。
          def leave_configuration_commands = ["end"]

          # 只认可本厂商明确的保存完成行，设备提示符返回本身不能证明持久化。
          def persistence_pattern = /\A(?:\[OK\]|Copy complete\.)\z/i

          # 每个 Device ID 表示一条应由模板解析的邻居记录。
          def expected_neighbor_count(output, _template)
            output.scan(/^\s*Device ID:\s*\S+/i).size
          end

          # 只有设备明确报告零 CDP 邻居时才认可空表。
          def empty_neighbor_output?(output)
            output.match?(/Total cdp entries displayed\s*:\s*0|no cdp neighbors/i)
          end

          # 复用公共接口描述命令，保留本机接口原名。
          def change_commands(change)
            Net::Connector::Interfaces::InterfaceDescription.commands(interface: change.interface, description: change.new_description)
          end
        end
      end
    end
  end
end
