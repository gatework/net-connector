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
          def initialize(device)
            @device = device
          end

          def self.supports?(_capability) = false
          def supports?(capability) = self.class.supports?(capability)

          def neighbor_command = nil
          def neighbor_template(_output) = nil
          def description_template = nil
          def expected_neighbor_count(_output, _template) = 0
          def empty_neighbor_output?(_output) = false
          def enter_configuration = nil
          def finish_commands = []
          def change_commands(_change) = []
          def protocol = :lldp
          def script_command(command) = command

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
