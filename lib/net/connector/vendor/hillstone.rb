# frozen_string_literal: true

require_relative "../device/base"
require_relative "hillstone/running_config"
require_relative "hillstone/tftp_backup"
require_relative "hillstone/topology"

module Net
  module Connector
    module Hillstone
      # 山石 StoneOS 命令行和原生启动配置导出连接器。
      class Connector < Net::Connector::Base
        vendor :hillstone
        profile do
          running_config_strategy Net::Connector::Hillstone::RunningConfig
          tftp_strategy Net::Connector::Hillstone::TftpBackup
          topology_strategy Net::Connector::Hillstone::Topology
          commands do
            running_config "terminal length 0", "show configuration running"
            save_config "save all"
          end

          prompts do
            login(/(?:\A|(?<=[\r\n]))\S+(?:[#>$]|\([MBF]\))\s*\z/)
            command(/(?:\A|(?<=[\r\n]))\S+(?:#|\([MBF]\))\s*\z/)
          end

          pager do
            pattern(/(?:\A|(?<=[\r\n]))[ \t]*--More--[ \t\x00\x08]*(?=\r|\n|\z)/i)
          end

          errors do
            command(/^[ \t]*\^-+/i, /^\s*\^/,
                    /^[ \t]*(?:Unknown|Invalid|Error)\s+command/i,
                    /^[ \t]*Error:\s*[^\r\n]+/i)
          end

          command_timeout 60
        end
      end
    end
  end
end
