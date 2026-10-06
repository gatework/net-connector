# frozen_string_literal: true

require_relative "../cisco_ios/running_config"

module Net
  module Connector
    module CiscoNxos
      # 分页交互由引擎处理；响应正文中的进度或命令示例必须原样保留。
      class RunningConfig < CiscoIos::RunningConfig
      end
    end
  end
end
