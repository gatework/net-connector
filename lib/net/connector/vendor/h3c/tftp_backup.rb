# frozen_string_literal: true

require_relative "../../device/tftp/file_upload"

module Net
  module Connector
    module H3c
      class TftpBackup < Tftp::FileUpload
        # 自动探测选择的是启动配置；显式文件仍不能推断为运行或启动配置。
        def receipt_metadata(target, source_file:, explicit_source:)
          super.merge(configuration_kind: explicit_source ? :saved_file : :startup)
        end

        # 选取并校验 H3C 启动配置文件路径。
        def resolve_source_file(value)
          return TftpTarget.validate_source_file!(value) if value

          output = @device.execute_command("display startup").value!
          rendered = TerminalRenderer.render(output)
          path = rendered[/^\s*Next main startup saved-configuration file:\s*(\S+)/i, 1]
          path ||= rendered[/^\s*Current startup saved-configuration file:\s*(\S+)/i, 1]
          if path.nil? || path.casecmp?("NULL")
            raise DeviceError.new("device has no saved startup configuration",
                                  code: :startup_config_missing, host: @device.host, phase: :tftp_backup)
          end

          TftpTarget.validate_source_file!(path.sub(/\(\*\)\z/, ""))
        end
      end
    end
  end
end
