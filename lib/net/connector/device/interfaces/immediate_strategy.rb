# frozen_string_literal: true

require_relative "strategy"
require_relative "interface_blocks"
require_relative "../../engine/terminal/renderer"

module Net
  module Connector
    class Interfaces
      # 接口描述立即生效的设备：退出视图、读回、保存是不同阶段，不能在 finish 中提前保存。
      class ImmediateStrategy < Strategy
        include InterfaceBlocks

        # 使用配置采集命令读回即时生效的接口描述。
        def verification_commands = @device.config_commands
        # 使用厂商保存命令将运行配置写入持久配置。
        def persistence_commands = @device.profile.save_commands

        # 完成提示必须来自保存步骤；原文和渲染文本中的失败优先，单独提示符/进度不算确认。
        def persistence_confirmed?(result)
          !result.steps.empty? && result.steps.all? do |step|
            raw = step.output.delete_suffix(step.prompt.to_s)
            history = raw.gsub(/\e\[[0-9;:]*m/, "").gsub(/\r(?!\n)/, "\n")
            rendered = Terminal::Renderer.render(raw)
            failure = /\b(?:error|failed|failure|denied|cannot|unable|unsuccessful|aborted)\b/i
            next false if history.match?(failure) || Terminal::Renderer.render(history).match?(failure) || rendered.match?(failure)

            rendered.lines("\n").any? { |line| line.strip.match?(persistence_pattern) }
          end
        end

        # 没有明确完成证据的策略不能借用一个泛化的成功关键词。
        def persistence_pattern = /\A\b\B\z/
      end
    end
  end
end
