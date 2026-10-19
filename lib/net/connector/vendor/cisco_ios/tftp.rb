# frozen_string_literal: true

require_relative "../cisco"
require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module Vendor
      class CiscoIos < Cisco
        # 通过交互复制运行配置，以设备的复制完成行确认上传。
        class Tftp < Net::Connector::Tftp::Strategy
          # 在连接前拒绝当前厂商不支持的参数组合。
          def validate_options!(_target, source_file:, vrf: nil)
            raise ArgumentError, "Cisco IOS does not use source_file" unless source_file.nil?
            raise ArgumentError, "Cisco IOS TFTP backup does not use vrf" unless vrf.nil?
          end

          # 声明本厂商实际导出的配置种类与格式，不推断服务器文件已核验。
          def receipt_metadata(_target, **) = { configuration_kind: :running, format: :cfg }

          # 检查设备回显是否确认 TFTP 传输完成。
          def device_reported_complete?(result)
            completion_lines(result).any? do |line|
              copied_bytes?(line) || line.match?(/\A\[OK(?:\s*-\s*[1-9]\d*\s+bytes)?\]\z/i)
            end
          end

          private

          # 生成 IOS 原生运行配置上传命令，实际目标由后续交互填写。
          def transfer_command(_target, **) = "copy running-config tftp:"

          # 按 IOS 提示填写服务器和文件名，并只接受预期的目标确认。
          def transfer_interactions(target, **)
            [interaction(/Address\s+or\s+name\s+of\s+remote\s+host\s*\[[^\]]*\]\?\s*\z/i, "#{target.host}\n"),
             interaction(/Destination\s+filename\s*\[[^\]]*\]\?\s*\z/i, "#{target.path}\n")]
          end
        end
      end
    end
  end
end
