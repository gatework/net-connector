# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module Vendor
      class Centec < Net::Connector::Base
        # 通过设备原生命令导出运行配置，可为本次上传选择管理口路由。
        class Tftp < Net::Connector::Tftp::Strategy
          # 在建立设备会话前拒绝 Centec 不支持的源文件及 VRF 选项。
          def validate_options!(_target, source_file:, vrf: nil)
            raise ArgumentError, "Centec TFTP backup does not use source_file" unless source_file.nil?
            raise ArgumentError, "Centec TFTP backup does not use vrf" unless vrf.nil?
          end

          # 校验源接口仅为本次导出支持的管理口选择，不修改全局设备设置。
          def validate_source_interface!(_target, source_interface:)
            return if source_interface.nil? || %w[management data].include?(source_interface)

            raise ArgumentError, "Centec TFTP source_interface must be management or data"
          end

          # 声明设备原生导出产物为文本运行配置，不代表服务器文件已核验。
          def receipt_metadata(_target, **) = { configuration_kind: :running, format: :cfg }

          # 只接受设备明确报告非零字节的成功传输行，避免空文件被判完成。
          def device_reported_complete?(result)
            completion_lines(result).any? do |line|
              line.match?(/\ASent\s+[1-9]\d*\s+bytes\s+in\s+[\d.]+\s+seconds?[.!]?\z/i)
            end
          end

          private

          # 生成 Centec 原生 TFTP URL 命令，仅在显式选择时附加管理接口。
          def transfer_command(target, source_interface: nil, **)
            interface = source_interface == "management" ? " mgmt-if" : ""
            "copy running-config#{interface} tftp://#{target.host}/#{target.path}"
          end
        end
      end
    end
  end
end
