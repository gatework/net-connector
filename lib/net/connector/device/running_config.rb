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

      def finish(result)
        step = @device.send(:config_result_step, result)
        raise incomplete("configuration collection has no completed configuration step") unless step

        content = @device.clean_config(step.output)
        unless content.is_a?(String) && !content.strip.empty? && content?(step)
          raise incomplete("configuration collection returned empty content")
        end
        Result.new(steps: result.steps, config: content)
      end

      def prompt_for(command, strategy)
        return command.prompt if command.prompt

        prompt = strategy.prompt_text(command)
        if prompt.empty?
          raise PromptError.new("configuration collection has no known device prompt", host: @device.host, phase: :collect)
        end
        /(?:\A|(?<=[\r\n]))[ \t\x00]*#{Regexp.escape(prompt)}[ \t\x00]*[\r\n]*\z/
      end

      def content?(step)
        body = TerminalRenderer.render(step.output.delete_suffix(step.prompt.to_s)).strip
        lines = body.lines
        lines.shift if lines.first&.strip == step.command.text
        !lines.join.strip.empty?
      end

      def incomplete(message)
        DeviceError.new(message, code: :incomplete_configuration, host: @device.host, phase: :collect)
      end
    end
  end
end
