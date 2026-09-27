# frozen_string_literal: true

require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module CiscoIos
      class TftpBackup < Tftp::Strategy
        # 在连接前拒绝当前厂商不支持的参数组合。
        def validate_options!(_target, source_file:, vrf: nil)
          raise ArgumentError, "Cisco IOS does not use source_file" unless source_file.nil?
          raise ArgumentError, "Cisco IOS TFTP backup does not use vrf" unless vrf.nil?
        end

        def receipt_metadata(_target, **) = { configuration_kind: :running, format: :cfg }

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          validate_options!(target, source_file: source_file, vrf: vrf)

          Script.new([Command.new("copy running-config tftp:", timeout: 180,
                                  interactions: [
                                    interaction(/Address\s+or\s+name\s+of\s+remote\s+host\s*\[[^\]]*\]\?\s*\z/i,
                                                "#{target.host}\n"),
                                    interaction(/Destination\s+filename\s*\[[^\]]*\]\?\s*\z/i,
                                                "#{target.path}\n")
                                  ])])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def device_reported_complete?(result)
          completion_lines(result).any? do |line|
            copied_bytes?(line) || line.match?(/\A\[OK(?:\s*-\s*[1-9]\d*\s+bytes)?\]\z/i)
          end
        end
      end
    end
  end
end
