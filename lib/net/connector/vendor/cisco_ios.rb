# frozen_string_literal: true

require_relative "cisco"
require_relative "cisco_ios/tftp"

module Net
  module Connector
    module Vendor
      # Cisco IOS 和 IOS-XE 配置采集连接器。
      class CiscoIos < Cisco
        vendor :cisco_ios
        # 声明 IOS 的命令、提示、分页、诊断和保存确认规则。
        profile do
          tftp_strategy Tftp
          commands do
            save_config "copy running-config startup-config"
          end

          prompts do
            login(/(?:\A|(?<=[\r\n]))\S+[>#]\s*\z/)
            command(/(?:\A|(?<=[\r\n]))\S+#\s*\z/)
          end

          pager do
            pattern(/(?:\A|(?<=[\r\n]))[^\S\r\n]*--More--[^\r\n]*(?=\r|\n|\z)/i)
          end

          errors do
            command(/^[ \t]*%[ \t]+(?:Invalid|Incomplete|Ambiguous)\s+(?:input|command)\b/i, /^[ \t]*\^/)
          end

          interactions do
            confirm(/Proceed\s+with\s+copy\?\s*\[confirm\]\s*\z/i, response: "\n")
          end
        end
      end
    end
  end
end
