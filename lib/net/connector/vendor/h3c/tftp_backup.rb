# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module H3c
      class TftpBackup < Operations::Tftp::Strategy
        # 选取并校验 H3C 启动配置文件路径。
        def source_file(value)
          return TftpTarget.validate_source_file!(value) if value

          output = @device.execute("display startup").value!
          rendered = TerminalRenderer.render(output)
          path = rendered[/^\s*Next main startup saved-configuration file:\s*(\S+)/i, 1]
          path ||= rendered[/^\s*Current startup saved-configuration file:\s*(\S+)/i, 1]
          if path.nil? || path.casecmp?("NULL")
            raise DeviceError.new("device has no saved startup configuration",
                                  code: :startup_config_missing, host: @device.host, phase: :tftp_backup)
          end

          TftpTarget.validate_source_file!(path.sub(/\(\*\)\z/, ""))
        end

        # 根据 H3C 源文件确定默认导出名称。
        def default_path(source_file) = File.basename(source_file)

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          raise ArgumentError, "H3C TFTP backup does not use vrf" if vrf

          destination = target.explicit_path? ? " #{target.path}" : ""
          Script.new([Command.new("tftp #{target.host} put #{source_file}#{destination}", timeout: 180)])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def complete?(result)
          completion_lines(result).any? { |line| completed_upload?(line) }
        end
      end
    end
  end
end
