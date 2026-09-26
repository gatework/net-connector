# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module PaloAlto
      class TftpBackup < Operations::Tftp::Strategy
        FILENAME = "running-config.xml"

        # 返回 PAN-OS 固定使用的运行配置文件名。
        def self.filename(_host, **) = FILENAME

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          raise ArgumentError, "PAN-OS does not use source_file" if source_file
          raise ArgumentError, "PAN-OS TFTP backup does not use vrf" if vrf
          unless target.path == FILENAME
            raise ArgumentError, "PAN-OS TFTP export uses the fixed filename #{FILENAME}"
          end

          Script.new([Command.new("tftp export configuration to #{target.host} from #{FILENAME}",
                                  timeout: 180)])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def complete?(result)
          completion_lines(result).any? do |line|
            line.match?(/\ASent\s+[1-9]\d*\s+bytes(?:\s+in\s+[\d.]+\s+(?:secs?|seconds?))?[.!]?\z/i)
          end
        end

        # 返回 PAN-OS 实际上传的固定文件名。
        def remote_path(_target, _result) = FILENAME
      end
    end
  end
end
