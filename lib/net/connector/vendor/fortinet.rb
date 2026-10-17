# frozen_string_literal: true

require_relative "../device/base"
require_relative "fortinet/tftp"
require_relative "fortinet/topology"

module Net
  module Connector
    module Vendor
      # FortiGate/FortiOS 使用当前授权视图；采集不修改持久化的 console 或 VDOM 设置。
      class Fortinet < Net::Connector::Base
        vendor :fortinet
        profile do
          running_config_strategy Net::Connector::RunningConfig::Rendered
          tftp_strategy Tftp
          topology_strategy Topology
          commands do
            running_config "show full-configuration"
            save_config "execute cfg save"
          end
          prompts do
            login(/(?:\A|(?<=[\r\n]))[^\s#>$]+(?:[ \t]+\([^\r\n()]+\))?[ \t]*[#\$][ \t]*\z/)
            command(/(?:\A|(?<=[\r\n]))[^\s#>$]+(?:[ \t]+\([^\r\n()]+\))?[ \t]*[#\$][ \t]*\z/)
          end
          pager do
            pattern(/(?:\A|(?<=[\r\n]))[ \t]*--More--[ \t\x00\x08]*(?=\r|\n|\z)/)
          end
          errors do
            command(/^[ \t]*(?:command parse error|Command fail\.|Unknown action\b|Unknown command\b)/i,
                    /^[ \t]*(?:Permission denied|Access denied|Sorry, you have no permission)\b/i)
          end
          interactions do
            login(/Press any key to continue[^\r\n]*\z/i, response: " ", capture: false)
          end
          command_timeout 120
        end
      end
    end
  end
end
