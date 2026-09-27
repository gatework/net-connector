# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module CiscoNxos
      class TftpBackup < Operations::Tftp::Strategy
        # 在连接前拒绝当前厂商不支持的参数组合。
        def validate_options!(_target, source_file:, **)
          raise ArgumentError, "Cisco NX-OS does not use source_file" unless source_file.nil?
        end

        def receipt_metadata(_target, **) = { configuration_kind: :running, format: :cfg }

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          validate_options!(target, source_file: source_file, vrf: vrf)

          vrf ||= "management"
          command = "copy running-config tftp://#{target.host}/#{target.path} vrf #{vrf}"
          Script.new([Command.new(command, timeout: 180,
                                  interactions: [
                                    interaction(/Enter\s+vrf\s*\([^\r\n]*\):\s*\z/i,
                                                "#{vrf}\n")
                                  ])])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def complete?(result)
          completion_lines(result).any? do |line|
            line.match?(/\A
              (?:transfer|copy)(?:\s+operation)?\s+
              (?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?(?:\s+successfully)?)[.!]?
              \z/ix) || copied_bytes?(line)
          end
        end
      end
    end
  end
end
