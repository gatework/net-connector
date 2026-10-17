# frozen_string_literal: true

require_relative "cisco"
require_relative "cisco_nxos/tftp"
require_relative "cisco_nxos/topology"

module Net
  module Connector
    module Vendor
      # Cisco Nexus 9000 和 NX-OS 配置采集连接器。
      class CiscoNxos < Cisco
        vendor :cisco_nxos
        # 声明 NX-OS 的命令、提示、分页、诊断和保存确认规则。
        profile do
          tftp_strategy Tftp
          topology_strategy Topology
          commands do
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
        end
      end
    end
  end
end
