# frozen_string_literal: true

require_relative "../../operations/tftp/strategy"

module Net
  module Connector
    module Huawei
      class TftpBackup < Operations::Tftp::Strategy
        # 要求调用方提供合法的华为启动配置文件路径。
        def source_file(value)
          raise ArgumentError, "Huawei TFTP backup requires source_file" unless value

          TftpTarget.validate_source_file!(value)
        end

        # 根据华为配置源文件确定默认导出名称。
        def default_path(source_file) = File.basename(source_file)

        # 构造当前厂商的 TFTP 导出交互脚本。
        def script(target, source_file:, vrf: nil)
          raise ArgumentError, "Huawei TFTP backup does not use vrf" if vrf

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
