# frozen_string_literal: true

require_relative "command"
require_relative "result"

module Net
  module Connector
    # 单个脚本的局部状态；执行对象不拥有设备或传输层生命周期。
    class Execution
      attr_reader :context, :steps

      # 保存命令准备和后处理钩子，并初始化批次上下文及已完成步骤。
      def initialize(session:, timeout:, prepare:, after_command:, prompt: nil)
        @session = session
        @command_timeout = timeout
        @prepare_command = prepare
        @after_command = after_command
        @prompt = prompt
        @context = {}
        @steps = []
      end

      # 依次准备、执行和记录脚本命令；失败时保留已完成步骤并统一抛错。
      def execute(script)
        script.each do |original|
          @session.command_scope(original) do
            @current_command = original
            command = @prepare_command.call(original, self)
            next unless command

            @current_command = command
            started = Expect.monotonic
            response = query(command)
            step = CommandResult.new(command: command, output: response.output, prompt: response.prompt,
                                     duration: Expect.monotonic - started)
            steps << step
            # 设备已经完成命令；后处理失败也不能从部分结果中抹去其副作用。
            @after_command.call(command, response, self)
            yield step if block_given?
          rescue => error
            raise @session.normalize_error(error, phase: :script, command: @current_command), cause: nil
          end
        end
        Result.new(steps: steps)
      end

      # 厂商后续查询复用同一信道和错误处理，不开启新的批处理。
      def query(command)
        command = Command.new(command) unless command.is_a?(Command)
        @session.exchange(command, timeout: @command_timeout, prompt: @prompt&.call(command))
      end

      # 只有当前会话未特权时才执行特权认证。
      def enable(command, prompt)
        @session.enable(command, prompt) unless @session.privileged?
      end

      # 根据当前命令建立脚本阶段错误。
      def failure(message)
        @session.error(ScriptError, message, phase: :script, command: @current_command)
      end
    end
  end
end
