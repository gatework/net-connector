# frozen_string_literal: true

require_relative "../cisco"
require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module Vendor
      class CiscoNxos < Cisco
        # 在指定 VRF 上传 NX-OS 运行配置，默认使用 management。
        class Tftp < Net::Connector::Tftp::Strategy
          DEFAULT_VRF = "management"
          private_constant :DEFAULT_VRF

          # 在连接前拒绝当前厂商不支持的参数组合。
          def validate_options!(_target, source_file:, **)
            raise ArgumentError, "Cisco NX-OS does not use source_file" unless source_file.nil?
          end

          # 声明本厂商实际导出的配置种类与格式，不推断服务器文件已核验。
          def receipt_metadata(_target, **) = { configuration_kind: :running, format: :cfg }

          # 检查设备回显是否确认 TFTP 传输完成。
          def device_reported_complete?(result)
            completion_lines(result).any? do |line|
              line.match?(/\A
                (?:transfer|copy)(?:\s+operation)?\s+
                (?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?(?:\s+successfully)?)[.!]?
                \z/ix) || copied_bytes?(line)
            end
          end

          private

          # 生成 NX-OS 的 TFTP URL 导出命令，并按需要启用 VRF 交互。
          def transfer_command(target, vrf: nil, **)
            "copy running-config tftp://#{target.host}/#{target.path} vrf #{vrf || DEFAULT_VRF}"
          end

          # 仅在指定 VRF 时回答设备的路由实例选择提示。
          def transfer_interactions(_target, vrf: nil, **)
            [interaction(/Enter\s+vrf\s*\([^\r\n]*\):\s*\z/i, "#{vrf || DEFAULT_VRF}\n")]
          end
        end
      end
    end
  end
end
