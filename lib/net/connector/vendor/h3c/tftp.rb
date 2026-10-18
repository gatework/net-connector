# frozen_string_literal: true

require "ipaddr"
require_relative "../../device/base"
require_relative "../../device/tftp/file_upload"

module Net
  module Connector
    module Vendor
      class H3c < Net::Connector::Base
        # 未指定源文件时探测 H3C 启动配置，显式文件不推断配置种类。
        class Tftp < Net::Connector::Tftp::FileUpload
          # management 使用本设备连接地址；具体接口使用单次 source interface，不修改全局设置。
          def validate_source_interface!(_target, source_interface:)
            return if source_interface.nil?
            unless source_interface.is_a?(String) && (source_interface == "management" || interface_parts(source_interface))
              raise ArgumentError, "H3C source_interface must be management or an interface type and number"
            end
            if source_interface == "management" && !IPAddr.new(@device.host).ipv4?
              raise ArgumentError, "H3C management TFTP source requires an IPv4 device address"
            end
          rescue IPAddr::Error
            raise ArgumentError, "H3C management TFTP source requires an IPv4 device address", cause: nil
          end

          # 自动探测选择的是启动配置；显式文件仍不能推断为运行或启动配置。
          def receipt_metadata(target, source_file:, explicit_source:)
            super.merge(configuration_kind: explicit_source ? :saved_file : :startup)
          end

          # 选取并校验 H3C 启动配置文件路径。
          def resolve_source_file(value)
            return TftpTarget.validate_source_file!(value) if value

            output = @device.execute_command("display startup").value!
            rendered = Terminal::Renderer.render(output)
            path = rendered[/^\s*Next main startup saved-configuration file:\s*(\S+)/i, 1]
            path ||= rendered[/^\s*Current startup saved-configuration file:\s*(\S+)/i, 1]
            if path.nil? || path.casecmp?("NULL")
              raise DeviceError.new("device has no saved startup configuration",
                                    code: :startup_config_missing, host: @device.host, phase: :tftp_backup)
            end

            TftpTarget.validate_source_file!(path.sub(/\(\*\)\z/, ""))
          end

          private

          def transfer_command(target, source_file:, source_interface: nil, **)
            super(target, source_file: source_file) + source_interface_suffix(source_interface)
          end

          def interface_parts(value) = /\A([A-Za-z][A-Za-z-]*) ?([0-9][0-9\/.:]*)\z/.match(value)

          def source_interface_suffix(value)
            return "" if value.nil?
            return " source ip #{IPAddr.new(@device.host)}" if value == "management"

            parts = interface_parts(value)
            " source interface #{parts[1]} #{parts[2]}"
          end
        end
      end
    end
  end
end
