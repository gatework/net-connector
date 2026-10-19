# frozen_string_literal: true

require_relative "../device/base"
require_relative "centec/running_config"
require_relative "centec/tftp"

module Net
  module Connector
    module Vendor
      # 声明 Centec/DclingCloudOS 的配置采集、保存、提示符和原生 TFTP 能力。
      class Centec < Net::Connector::Base
        vendor :centec

        profile do
          running_config_strategy RunningConfig
          tftp_strategy Tftp
          commands do
            running_config "terminal length 0", "show running-config"
            save_config "copy running-config startup-config"
          end
          prompts do
            login(/(?:\A|(?<=[\r\n]))\S+[>#]\s*\z/)
            command(/(?:\A|(?<=[\r\n]))\S+[>#]\s*\z/)
          end
          errors do
            command(/^[ \t]*%[ \t]+(?:Syntax\s+error|Invalid|Incomplete|Ambiguous|Unknown|Error)\b/i)
          end
          command_timeout 60
        end
      end
    end
  end
end
