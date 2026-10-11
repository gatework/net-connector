# frozen_string_literal: true

require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module Radware
      # 复用终端渲染策略，在配置菜单中保持已认证的设备提示身份。
      class RunningConfig < Net::Connector::RunningConfig::Rendered
        # /cfg/dump 进入 Configuration 菜单；保留设备前缀，只替换菜单名称。
        def prompt_text(command)
          prompt = super
          return prompt unless command.text == "/cfg/dump"

          prompt.sub(/\A(>>[ \t]+(?:.* - )?)[^\r\n#]+#\z/, '\1Configuration#')
        end
      end
    end
  end
end
