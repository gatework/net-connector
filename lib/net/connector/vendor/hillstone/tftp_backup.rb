# frozen_string_literal: true

require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module Hillstone
      class TftpBackup < Tftp::Strategy
        # 山石原生导出的配置文件使用 dat 扩展名。
        def self.file_extension = "dat"

        # 在连接前拒绝源文件及远端目录；未指定文件名时仍由设备生成。
        def validate_options!(target, source_file:, **)
          raise ArgumentError, "Hillstone TFTP export does not use source_file" unless source_file.nil?
          return unless target.explicit_path? && target.path.include?("/")

          raise ArgumentError, "Hillstone TFTP filename cannot contain a directory"
        end

        def receipt_metadata(target, **)
          { configuration_kind: :startup, format: :dat, requested_path: target.explicit_path? ? target.path : nil }
        end

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          validate_options!(target, source_file: source_file, vrf: vrf)

          command = "export configuration startup to tftp server #{target.host} vrouter #{vrf || "mgt-vr"}"
          command += " #{target.path}" if target.explicit_path?
          Script.new([Command.new(command, timeout: 180)])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def device_reported_complete?(result)
          !completion_line(result).nil?
        end

        # 从山石成功回显提取实际目标文件名。
        def remote_path(_target, result)
          filename = completion_line(result)&.split&.last
          TftpTarget.validate_path!(filename)
        end

        private

        # 仅认可设备明确给出目标文件名的 Export ok 回显。
        def completion_line(result)
          completion_lines(result).find { |line| line.match?(/\AExport\s+ok\s*,\s*target\s+file\s+name\s+\S+\z/i) }
        end
      end
    end
  end
end
