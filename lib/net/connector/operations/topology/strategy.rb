# frozen_string_literal: true

require "shellwords"
require_relative "../../device/interface_description"

module Net
  module Connector
    module Operations
      class Topology
        autoload :Cisco, File.expand_path("cisco", __dir__)
        autoload :H3c, File.expand_path("h3c", __dir__)
        autoload :Hillstone, File.expand_path("hillstone", __dir__)
        autoload :PaloAlto, File.expand_path("palo_alto", __dir__)
        autoload :Radware, File.expand_path("radware", __dir__)

        # 厂商拓扑规则；默认不提供任何设备能力。
        class Strategy
          # 保存设备供厂商规则查询档案和会话状态。
          def initialize(device)
            @device = device
          end

          # 声明策略类支持的拓扑能力，默认全部关闭。
          def self.supports?(_capability) = false

          # 将实例级能力查询交给策略类声明。
          def supports?(capability) = self.class.supports?(capability)

          # 返回读取邻居的命令，未定义时不支持发现。
          def neighbor_command = nil

          # 根据原始输出选择邻居解析模板。
          def neighbor_template(_output) = nil

          # 返回当前接口描述所用的解析模板。
          def description_template = nil

          # 返回输出中应解析出的邻居数量，供完整性校验使用。
          def expected_neighbor_count(_output, _template) = 0

          # 只有明确的空表证据才允许返回空邻居列表。
          def empty_neighbor_output?(_output) = false

          # 返回进入设备配置视图的命令。
          def enter_configuration = nil

          # 返回离开配置视图和保存配置所需的命令。
          def finish_commands = []

          # 未声明分阶段契约的旧策略仍可读取，但不能推断其退出、验证和保存的安全边界。
          def leave_configuration = nil
          def verification_commands = nil
          def persistence_commands = nil
          def persistence_confirmed?(_result) = false
          def change_error_code = :description_unsupported

          # 只读策略可以没有完整性扩展；立即生效的接口块模型会进一步校验解析数量。
          def validate_descriptions!(_config, _rows) end

          # 为一条接口描述变更生成厂商命令。
          def change_commands(_change) = []

          # 标明邻居发现使用的协议。
          def protocol = :lldp

          # 在下发前允许厂商调整命令对象及超时。
          def script_command(command) = command

          # 将发现接口名归一为查找当前配置所用的键。
          def interface_key(name) = InterfaceName.key(name)

          # 将发现协议常用的接口简称展开为配置视图可识别的名称。
          def configuration_interface(name) = InterfaceName.configuration(name)

          # 还原 PAN-OS set 配置或 Alteon dump 中的引号描述。
          def decode_description(value)
            value = value.strip
            value.start_with?('"') ? Shellwords.split(value).join(" ") : value
          rescue ArgumentError
            value
          end

        end
      end
    end
  end
end
