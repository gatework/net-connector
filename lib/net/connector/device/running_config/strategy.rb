# frozen_string_literal: true

require_relative "../../engine/terminal_renderer"

module Net
  module Connector
    class RunningConfig
      class Strategy
        # 保存策略所属设备，供提示符和厂商校验使用。
        def initialize(device) = @device = device

        # 默认保留设备响应原文。
        def clean(text) = text

        # 默认取脚本最后一个完成步骤作为运行配置。
        def result_step(result) = result.steps.last

        # 普通采集命令保持视图不变；需要切换视图的采集策略显式调整。
        def prompt_text(_command)
          TerminalRenderer.render(@device.current_prompt.to_s).lines.last.to_s.strip
        end

        # 公共策略不增加逐命令响应检查。
        def check_response(_command, _response, _execution) end
      end

      # 使用终端行编辑规则渲染 H3C、Huawei 和 Radware 配置。
      class Rendered < Strategy
        # 应用终端行编辑规则，还原设备最终显示的配置文本。
        def clean(text) = TerminalRenderer.render(text)
      end
    end
  end
end
