# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module Vendor
      class Centec < Net::Connector::Base
        # 仅删除响应边界的命令回显和提示符，保留横幅中内容相同的正文。
        class RunningConfig < Net::Connector::RunningConfig::Rendered
          # 先还原终端文本，再移除当前命令首行和末尾提示符。
          def clean(text)
            prompt = Terminal::Renderer.render(@device.current_prompt.to_s).strip
            config = super.sub(/\A(?:#{Regexp.escape(prompt)})?show\s+running-config[ \t]*\n/, "")
            config.sub(/(?:\A|\n)#{Regexp.escape(prompt)}[ \t]*\z/, "\n")
          end
        end
      end
    end
  end
end
