# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/tftp/strategy"

module Net
  module Connector
    module Vendor
      class Radware < Net::Connector::Base
        # 交互导出 Alteon 原生 tgz 归档；回执不将归档推断为文本运行配置。
        class Tftp < Net::Connector::Tftp::Strategy
          # Radware 原生导出生成压缩配置归档。
          def self.file_extension = "tgz"

          # 在连接前拒绝当前厂商不支持的参数组合。
          def validate_options!(_target, source_file:, vrf: nil)
            raise ArgumentError, "Radware Alteon does not use source_file" unless source_file.nil?
            raise ArgumentError, "Radware TFTP backup does not use vrf" unless vrf.nil?
          end

          def validate_source_interface!(_target, source_interface:)
            return if source_interface.nil? || %w[management data].include?(source_interface)

            raise ArgumentError, "Radware source_interface must be management or data"
          end

          # 声明本厂商实际导出的配置种类与格式，不推断服务器文件已核验。
          def receipt_metadata(_target, **) = { configuration_kind: :native_archive, format: :tgz }

          # 检查设备回显是否确认 TFTP 传输完成。
          def device_reported_complete?(result)
            completion_lines(result).any? do |line|
              line.match?(/\A
                (?:Current\s+)?(?:configuration|config)\s+
                (?:successfully\s+(?:uploaded|tftp'd)|(?:uploaded|tftp'd)(?:\s+successfully)?|
                  complete(?:d)?(?:\s+successfully)?)[.!]?
                \z/ix)
            end
          end

          private

          def transfer_command(target, source_interface: nil, **)
            flag = { "management" => " -mgmt", "data" => " -data" }.fetch(source_interface, "")
            "/cfg/ptcfg #{target.host} -tftp#{flag}"
          end

          def transfer_interactions(target, **)
            [interaction(/Enter\s+(?:hostname|IP address)[^\r\n]*:\s*\z/i, "#{target.host}\n"),
             interaction(/Enter\s+name\s+of\s+(?:\.tgz\s+)?file[^\r\n]*:\s*\z/i, "#{target.path}\n"),
             interaction(/Enter\s+username[^\r\n]*:\s*\z/i, "\n"),
             interaction(/Include\s+private\s+keys\?\s*\[y\/n\]:\s*\z/i, "n\n"),
             interaction(/Enter\s+"?mansync"?\s+to\s+get\s+real\/group\/virt\s+internal\s+index\s+config:\s*\z/i, "mansync\n")]
          end
        end
      end
    end
  end
end
