# frozen_string_literal: true

require_relative "../device/base"
require_relative "cisco_ios/running_config"
require_relative "cisco_ios/tftp_backup"
require_relative "cisco_ios/topology"

module Net
  module Connector
    module CiscoIos
      # Cisco IOS 和 IOS-XE 配置采集连接器。
      class Connector < Net::Connector::Base
        vendor :cisco_ios
        # 声明 IOS 的命令、提示、分页、诊断和保存确认规则。
        profile do
          running_config_strategy Net::Connector::CiscoIos::RunningConfig
          tftp_strategy Net::Connector::CiscoIos::TftpBackup
          topology_strategy Net::Connector::CiscoIos::Topology
          commands do
            running_config "terminal length 0", "show running-config"
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

          command_timeout 60

          interactions do
            confirm(/Destination\s+filename\s+\[[^\]]+\]\?\s*\z/i, response: "\n")
            confirm(%r{Do\s+you\s+want\s+to\s+overwrite\?\s*\[yes/no\]\s*\z}i, response: "yes\n")
            confirm(/Proceed\s+with\s+copy\?\s*\[confirm\]\s*\z/i, response: "\n")
          end
        end
      end
    end
  end
end
