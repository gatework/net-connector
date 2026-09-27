# frozen_string_literal: true

require_relative "strategy"
require_relative "../../engine/terminal_renderer"

module Net
  module Connector
    module Operations
      class Topology
        # 接口描述立即生效的设备：退出视图、读回、保存是不同阶段，不能在 finish 中提前保存。
        class ImmediateStrategy < Strategy
          def verification_commands = @device.config_commands
          def persistence_commands = @device.profile.save_commands

          # 保留旧扩展查询入口；公共执行流程使用独立阶段，不再执行这份合并列表。
          def finish_commands = leave_configuration + persistence_commands

          # TextFSM 不能静默跳过未知接口头；否则目标行正确也不足以证明读回证据完整。
          def validate_descriptions!(config, rows)
            expected = config.scan(/^interface[ \t]+([^\r\n]*)/).flatten.map(&:strip)
            return if expected == rows.map { |row| row.fetch("INTERFACE").strip }

            raise ParsingError.new("interface description output was not fully recognized", code: :unrecognized_output,
                                   host: @device.host, phase: :verify)
          end

          # 完成提示必须来自保存步骤；原文和渲染文本中的失败优先，单独提示符/进度不算确认。
          def persistence_confirmed?(result)
            !result.steps.empty? && result.steps.all? do |step|
              raw = step.output.delete_suffix(step.prompt.to_s)
              rendered = TerminalRenderer.render(raw)
              failure = /\b(?:error|failed|failure|denied|cannot|unable|unsuccessful|aborted)\b/i
              next false if raw.match?(failure) || rendered.match?(failure)

              rendered.lines.any? { |line| line.strip.match?(persistence_pattern) }
            end
          end

          # 没有明确完成证据的策略不能借用一个泛化的成功关键词。
          def persistence_pattern = /\A\b\B\z/
        end
      end
    end
  end
end
