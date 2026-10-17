# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module Vendor
      class Hillstone < Net::Connector::Base
        # 山石配置保持原始文本，仅删除已识别的退格分页痕迹。
        class RunningConfig < Net::Connector::RunningConfig::Strategy
          # 去掉山石 CLI 用退格控制符绘制的分页痕迹。
          def clean(text) = text.gsub(/\x00?\x08+[ \t]+\x08+/, "")
        end
      end
    end
  end
end
