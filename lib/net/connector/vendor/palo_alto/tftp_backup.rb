# frozen_string_literal: true

require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module PaloAlto
      class TftpBackup < Tftp::Strategy
        FILENAME = "running-config.xml"

        # 返回 PAN-OS 固定使用的运行配置文件名。
        def self.filename(_host, **) = FILENAME

        # 默认文件名尚未生成时只校验显式目标；固定名冲突仍由批量计划拒绝。
        def validate_options!(target, source_file:, vrf: nil)
          raise ArgumentError, "PAN-OS does not use source_file" unless source_file.nil?
          raise ArgumentError, "PAN-OS TFTP backup does not use vrf" unless vrf.nil?
          return unless target.explicit_path? && target.path != FILENAME

          raise ArgumentError, "PAN-OS TFTP export uses the fixed filename #{FILENAME}"
        end

        def receipt_metadata(_target, **)
          { configuration_kind: :running, format: :xml, source_file: FILENAME }
        end

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          validate_options!(target, source_file: source_file, vrf: vrf)

          Script.new([Command.new("tftp export configuration to #{target.host} from #{FILENAME}",
                                  timeout: 180)])
        end

        # 检查设备回显是否确认 TFTP 传输完成。
        def device_reported_complete?(result)
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
