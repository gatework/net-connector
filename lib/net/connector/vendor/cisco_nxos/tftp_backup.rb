# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module CiscoNxos
      class TftpBackup < Operations::Tftp::Strategy
        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          raise ArgumentError, "Cisco NX-OS does not use source_file" if source_file

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
