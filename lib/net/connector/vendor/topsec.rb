# frozen_string_literal: true

require_relative "../device/base"

module Net
  module Connector
    module Vendor
      # TopOS 防火墙只读取运行配置；未验证的原生导出和保存流程不开放。
      class Topsec < Net::Connector::Base
        vendor :topsec
        profile do
          running_config_strategy Net::Connector::RunningConfig::Rendered
          commands { running_config "show-running nostop" }
          prompts do
            login(/(?:\A|(?<=[\r\n]))[^\s#>]*#\s*\z/)
            command(/(?:\A|(?<=[\r\n]))[^\s#>]*#\s*\z/)
          end
          errors do
            command(/^[ \t]*(?:%[ \t]*)?(?:Unknown|Invalid|Incomplete|Ambiguous)\s+command\b/i,
                    /^[ \t]*(?:Error:|Permission denied\b)/i)
          end
          command_timeout 120
        end
      end
    end
  end
end
