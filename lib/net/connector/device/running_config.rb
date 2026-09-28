# frozen_string_literal: true

require_relative "../engine/command"
require_relative "../engine/result"
require_relative "running_config/strategy"

module Net
  module Connector
    class RunningConfig
      # 设备只引入此能力；采集入口和策略作用域与采集流程一起维护。
      module Capability
        # 每次采集使用独立执行对象，设备只提供这一采集入口。
        def running_config = RunningConfig.new(self).call

        # 返回读取运行配置所需的设备命令；厂商必须声明。
        def config_commands
          commands = profile.config_commands
          return commands if commands

          raise NotImplementedError, "#{self.class} must define running configuration commands"
        end

        # 子类可覆盖并调用 super，复用本次响应检查积累的策略状态。
        def clean_config(text) = config_strategy.clean(text)

        protected

        # 默认取最后一个完成步骤；厂商策略可选择配置所在的业务步骤。
        def config_result_step(result) = config_strategy.result_step(result)

        private

        # 仅在持有会话锁的结果处理阶段绑定策略，退出时恢复原有作用域。
        # 同一设备上其他 Fiber 的离线清理不能借用此次采集状态。
        def with_config_strategy(strategy)
          previous = @config_strategy_scope
          @config_strategy_scope = [Fiber.current, strategy]
          yield
        ensure
          @config_strategy_scope = previous
        end

        def config_strategy
          scope = @config_strategy_scope
          scope && scope.first.equal?(Fiber.current) ? scope.last : RunningConfig.strategy(self)
        end
      end

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
        return Result.new(error: build_incomplete_error("configuration collection has no commands")) if script.empty?

        # 所有厂商的采集步骤都收紧输出边界，包括候选差异、模式切换及扩展查询。
        script = Script.new(script.map(&:with_output_sensitive))
        strategy = self.class.strategy(@device)
        prompt = ->(command) { prompt_for(command, strategy) }
        @device.execute_operation(script, name: :running_config, prompt: prompt,
                                  after_command: strategy.method(:validate_response!)) do |result|
          @device.send(:with_config_strategy, strategy) do
            finish(result)
          end
        end
      end

      private

      # 只从完成的配置步骤提取非空内容，并保留此前所有步骤。
      def finish(result)
        step = @device.send(:config_result_step, result)
        raise build_incomplete_error("configuration collection has no completed configuration step") unless step

        content = @device.clean_config(step.output)
        unless content.is_a?(String) && !content.strip.empty? && config_body?(step)
          raise build_incomplete_error("configuration collection returned empty content")
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
      def config_body?(step)
        body = TerminalRenderer.render(step.output.delete_suffix(step.prompt.to_s)).strip
        lines = body.lines
        lines.shift if lines.first&.strip == step.command.text
        !lines.join.strip.empty?
      end

      # 将缺少配置的情况统一映射为可识别的设备错误码。
      def build_incomplete_error(message)
        DeviceError.new(message, code: :incomplete_configuration, host: @device.host, phase: :collect)
      end
    end
  end
end
