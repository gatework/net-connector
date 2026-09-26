# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module Hillstone
      class TftpBackup < Operations::Tftp::Strategy
        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          raise ArgumentError, "Hillstone TFTP export does not use source_file" if source_file
          if target.explicit_path? && target.path.include?("/")
            raise ArgumentError, "Hillstone TFTP filename cannot contain a directory"
          end

          command = "export configuration startup to tftp server #{target.host} vrouter #{vrf || "mgt-vr"}"
          command += " #{target.path}" if target.explicit_path?
          Script.new([Command.new(command, timeout: 180)])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def complete?(result)
          !completion_line(result).nil?
        end

        # 从山石成功回显提取实际目标文件名。
        def remote_path(_target, result)
          filename = completion_line(result)&.split&.last
          TftpTarget.validate_path!(filename)
        end

        private

        def completion_line(result)
          completion_lines(result).find { |line| line.match?(/\AExport\s+ok\s*,\s*target\s+file\s+name\s+\S+\z/i) }
        end
      end
    end
  end
end
