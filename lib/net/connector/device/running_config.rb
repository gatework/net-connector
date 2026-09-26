# frozen_string_literal: true

require_relative "../engine/command"
require_relative "../engine/result"
require_relative "running_config/strategy"

module Net
  module Connector
    class RunningConfig
      # 保存需要读取运行配置的设备对象。
      def initialize(device)
        @device = device
      end

      # 从设备档案选定本次采集策略；无厂商规则时使用公共策略。
      def self.strategy(device)
        (device.profile.running_config_strategy || Strategy).new(device)
      end

      # 每次采集创建独立策略；响应校验、选择与清理共享状态，均在同一脚本锁内完成。
      def call
        script = Script.new(@device.config_commands)
        return Result.new(error: incomplete("configuration collection has no commands")) if script.empty?

        strategy = self.class.strategy(@device)
        prompt = ->(command) { prompt_for(command, strategy) }
        @device.execute_operation(script, name: :running_config, prompt: prompt,
                                  after_command: strategy.method(:check_response)) do |result|
          @device.send(:with_config_strategy, strategy) do
            finish(result)
          end
        end
      end

      private

      # 只从完成的配置步骤提取非空内容，并保留此前所有步骤。
      def finish(result)
        step = @device.send(:config_result_step, result)
        raise incomplete("configuration collection has no completed configuration step") unless step

        content = @device.clean_config(step.output)
        unless content.is_a?(String) && !content.strip.empty? && content?(step)
          raise incomplete("configuration collection returned empty content")
        end
        Result.new(steps: result.steps, config: content)
      end

      # 用当前完整提示符构建结束匹配，避免配置正文中的单个 # 提前结束采集。
      def prompt_for(command, strategy)
        return command.prompt if command.prompt

        prompt = strategy.prompt_text(command)
        if prompt.empty?
          raise PromptError.new("configuration collection has no known device prompt", host: @device.host, phase: :collect)
        end
        /(?:\A|(?<=[\r\n]))[ \t\x00]*#{Regexp.escape(prompt)}[ \t\x00]*[\r\n]*\z/
      end

      # 排除命令回显和提示符，确认响应确实包含配置正文。
      def content?(step)
        body = TerminalRenderer.render(step.output.delete_suffix(step.prompt.to_s)).strip
        lines = body.lines
        lines.shift if lines.first&.strip == step.command.text
        !lines.join.strip.empty?
      end

      # 将缺少配置的情况统一映射为可识别的设备错误码。
      def incomplete(message)
        DeviceError.new(message, code: :incomplete_configuration, host: @device.host, phase: :collect)
      end
    end
  end
end
