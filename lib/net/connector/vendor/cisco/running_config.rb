# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module Vendor
      class Cisco < Net::Connector::Base
        # 清理 IOS 响应头，保留 banner 和配置正文内的命令、时间等原始内容。
        class RunningConfig < Net::Connector::RunningConfig::Rendered
          # 每条命令已有独立响应；正文中的命令示例属于配置，不能按会话回显删除。
          # 只清理首个配置语句之前的时间注释，避免改写 banner 等多行文本。
          def clean(text)
            config = super
            config.sub(/\A(?:[ \t]*\n|![^\n]*\n|(?:\S+[#])?show[ \t]+running-config[^\n]*\n|
                          Building[ \t]+configuration[^\n]*\n|Current[ \t]+configuration[^\n]*\n)*/ix) do |header|
              header.gsub(/^!.*(?:Last\s+configuration\s+change|NVRAM\s+config).*\n/i, "")
            end
          end
        end
      end
    end
  end
end
