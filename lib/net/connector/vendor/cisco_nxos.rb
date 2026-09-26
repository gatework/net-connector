# frozen_string_literal: true

require_relative "../device/base"
require_relative "cisco_nxos/running_config"
require_relative "cisco_nxos/tftp_backup"
require_relative "cisco_ios/topology"

module Net
  module Connector
    module CiscoNxos
      # Cisco Nexus 9000 和 NX-OS 配置采集连接器。
      class Connector < Net::Connector::Base
        vendor :cisco_nxos
        # 声明 NX-OS 的命令、提示、分页、诊断和保存确认规则。
        profile do
          running_config_strategy Net::Connector::CiscoNxos::RunningConfig
          tftp_strategy Net::Connector::CiscoNxos::TftpBackup
          topology_strategy Net::Connector::CiscoIos::Topology
          commands do
            running_config "terminal length 0", "show running-config"
            save_config "copy run start"
          end

          prompts do
            login(/\S+[>#]\s*\z/)
            command(/\S+#\s*\z/)
          end

          pager do
            pattern(/(?:\A|(?<=[\r\n]))[ \t]*(?:\x1b\[[0-9;]*[A-Za-z])*--More--
              (?:[ \t\x00\x08]|\x1b\[[0-9;]*[A-Za-z])*(?=\r|\n|\z)/ix)
          end

          errors do
            command(
              /^[ \t]*%?[ \t]*(?:(?:Invalid|Ambiguous|Incomplete)\s+command(?:\s+\([^)]+\))?|
                Invalid\s+parameter\s+detected)\s+at\s+'\^'\s+marker\./ix,
              /^[ \t]*\^/,
              /^[ \t]*%[ \t]+(?:Invalid|Ambiguous|Incomplete)\s+command\b/i,
              /^[ \t]*%?[ \t]*Invalid\s+parameter\s+detected\b/i,
              /^[ \t]*syntax\s+error\b/i
            )
          end

          command_timeout 60

          interactions do
            confirm(/Destination\s+filename\s+\[[^\]]+\]\?\s*\z/i, response: "\n")
            confirm(%r{Do\s+you\s+want\s+to\s+overwrite\?\s*\[yes/no\]\s*\z}i, response: "yes\n")
          end
        end
      end
    end
  end
end
