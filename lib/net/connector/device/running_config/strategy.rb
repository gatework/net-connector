# frozen_string_literal: true

require_relative "../../engine/terminal_renderer"

module Net
  module Connector
    class RunningConfig
      class Strategy
        def initialize(device) = @device = device

        def clean(text) = text

        def result_step(result) = result.steps.last

        # 普通采集命令保持视图不变；需要切换视图的采集策略显式调整。
        def prompt_text(_command)
          TerminalRenderer.render(@device.current_prompt.to_s).lines.last.to_s.strip
        end

        def check_response(_command, _response, _execution) end
      end

      # 使用终端行编辑规则渲染 H3C、Huawei 和 Radware 配置。
      class Rendered < Strategy
        def clean(text) = TerminalRenderer.render(text)
      end
    end
  end
end
