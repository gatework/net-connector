# frozen_string_literal: true

require_relative "../../operations/tftp/file_upload"

module Net
  module Connector
    module H3c
      class TftpBackup < Operations::Tftp::FileUpload
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
      end
    end
  end
end
