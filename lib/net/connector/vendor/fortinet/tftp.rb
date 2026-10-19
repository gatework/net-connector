# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module Vendor
      class Fortinet < Net::Connector::Base
        # full-config 包含默认值；完成回执仅代表设备报告上传，不代替服务器核验。
        class Tftp < Net::Connector::Tftp::Strategy
          # 拒绝 FortiOS 原生导出不支持的源文件和 VRF 选项。
          def validate_options!(_target, source_file:, vrf: nil)
            raise ArgumentError, "FortiOS TFTP export does not use source_file" unless source_file.nil?
            raise ArgumentError, "FortiOS TFTP export does not use vrf" unless vrf.nil?
          end

          # 声明导出为文本运行配置，不推断服务器文件已经核验。
          def receipt_metadata(_target, **) = { configuration_kind: :running, format: :cfg }

          # 仅依据 FortiOS 明确的传输成功行确认设备报告完成。
          def device_reported_complete?(result)
            completion_lines(result).any? { |line| line.match?(/\ASend config file to tftp server OK\.?\z/i) }
          end

          private

          # 构造 FortiOS 完整配置导出到指定 TFTP 服务器的命令。
          def transfer_command(target, **) = "execute backup full-config tftp #{target.path} #{target.host}"
        end
      end
    end
  end
end
