# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module Radware
      class TftpBackup < Operations::Tftp::Strategy
        # 生成 Radware 压缩配置的远端文件名。
        def default_path(_source_file) = TftpTarget.filename(@device.host, extension: "tgz")

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          raise ArgumentError, "Radware Alteon does not use source_file" if source_file
          raise ArgumentError, "Radware TFTP backup does not use vrf" if vrf

          Script.new([Command.new("/cfg/ptcfg #{target.host} -tftp", timeout: 180, interactions: [
            interaction(/Enter\s+(?:hostname|IP address)[^\r\n]*:\s*\z/i, "#{target.host}\n"),
            interaction(/Enter\s+name\s+of\s+(?:\.tgz\s+)?file[^\r\n]*:\s*\z/i, "#{target.path}\n"),
            interaction(/Enter\s+username[^\r\n]*:\s*\z/i, "\n"),
            interaction(/Include\s+private\s+keys\?\s*\[y\/n\]:\s*\z/i, "n\n"),
            interaction(/Enter\s+"?mansync"?\s+to\s+get\s+real\/group\/virt\s+internal\s+index\s+config:\s*\z/i,
                        "mansync\n")
          ])])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def complete?(result)
          completion_lines(result).any? do |line|
            line.match?(/\A
              (?:Current\s+)?(?:configuration|config)\s+
              (?:successfully\s+(?:uploaded|tftp'd)|(?:uploaded|tftp'd)(?:\s+successfully)?|
                complete(?:d)?(?:\s+successfully)?)[.!]?
              \z/ix)
          end
        end
      end
    end
  end
end
