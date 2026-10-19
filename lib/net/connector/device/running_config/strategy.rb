# frozen_string_literal: true

require_relative "../../engine/terminal/renderer"

module Net
  module Connector
    class RunningConfig
      # 采集策略决定业务步骤、视图提示符和响应校验；默认不改写配置正文。
      class Strategy
        # 保存策略所属设备，供提示符和厂商校验使用。
        def initialize(device) = @device = device

        # 默认保留设备响应原文。
        def clean(text) = text

        # 默认取脚本最后一个完成步骤作为运行配置。
        def result_step(result) = result.steps.last

        # 普通采集命令保持视图不变；需要切换视图的采集策略显式调整。
        def prompt_text(_command)
          Terminal::Renderer.render(@device.current_prompt.to_s).lines("\n").last.to_s.strip
        end

        # 公共策略不增加逐命令响应检查。
        def validate_response!(_command, _response, _execution) end
      end

      # 按终端行编辑规则还原配置画面，厂商子类只清理已识别的响应头。
      class Rendered < Strategy
        # 应用终端行编辑规则，还原设备最终显示的配置文本。
        def clean(text) = rendered_response(text).dup

        # 复用不可变响应的渲染结果；向清理器返回独立副本，防止改写校验证据。
        def rendered_response(text)
          return Terminal::Renderer.render(text).freeze unless text.frozen?
          return @rendered_text if @rendered_source.equal?(text)

          @rendered_text = Terminal::Renderer.render(text).freeze
          @rendered_source = text
          @rendered_text
        end
      end
    end
  end
end
