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
        @prompt_resolver = prompt
        @context = {}
        @steps = []
        @output_bytes = 0
        @output_limit = session.configuration.max_script_output_bytes
        @sensitive = false
      end

      # 汇总实际执行的命令及交互，包括批次准备和厂商追加查询。
      def sensitive? = @sensitive

      # 依次准备、执行和记录脚本命令；失败时保留已完成步骤并统一抛错。
      def execute_script(script)
        script.each do |original_command|
          @session.with_command_redaction(original_command) do
            @current_command = original_command
            command = @prepare_command.call(original_command, self)
            next unless command

            @current_command = command
            started = Expect.monotonic
            step = nil
            response = execute_command(command) do |received|
              step = CommandResult.new(command: command, output: received.output, prompt: received.prompt,
                                       duration: Expect.monotonic - started)
              steps << step
            end
            # 设备已经完成命令；后处理失败也不能从部分结果中抹去其副作用。
            @after_command.call(command, response, self)
            yield step if block_given?
            validate_response_budget!(@last_executed_command)
          rescue => error
            raise @session.normalize_error(error, phase: :script, command: @current_command), cause: nil
          end
        end
        validate_response_budget!(@last_executed_command)
        Result.new(steps: steps)
      end

      # 厂商后续查询复用同一信道和错误处理，不开启新的批处理。
      def execute_command(command)
        command = Command.new(command) unless command.is_a?(Command)
        validate_send_budget!(command)
        prompt = @prompt_resolver&.call(command)
        # 提示符回调也可能追加查询，实际发送前重新检查它消耗的预算。
        validate_send_budget!(command) if @prompt_resolver
        response = @session.execute_command(command, timeout: @command_timeout, prompt: prompt) do |received|
          # 必须在 Session 恢复命令词表前读取；最终处理只能继承敏感性，不长期保留秘密。
          @sensitive ||= @session.redactor.sensitive?
          if received
            @last_executed_command = command
            @output_bytes += received.raw.bytesize
            # 完成事实先进入结果；日志失败不能抹去已执行命令，也不能触发重放。
            yield received if block_given?
          end
        end
        # 主命令先记录完整步骤，再检查超额；追加查询同样计入预算，但不改变原 steps 结构。
        validate_response_budget!(command)
        response
      end

      # 只有当前会话未特权时才执行特权认证。
      def enable(command, prompt)
        @session.enable(command, prompt) unless @session.privileged?
      end

      # 根据当前命令建立脚本阶段错误。
      def build_error(message)
        @session.build_error(ScriptError, message, phase: :script, command: @current_command)
      end

      private

      # 单响应上限仍约束正在读取的命令；累计预算阻止继续发送，不承诺设备尚未执行。
      def validate_send_budget!(command)
        return unless @output_limit && @output_bytes >= @output_limit

        raise_output_limit!(command)
      end

      # 恰好达到预算的已完成响应仍然有效；下一次发送由发送前检查阻止。
      def validate_response_budget!(command)
        return unless @output_limit && @output_bytes > @output_limit

        raise_output_limit!(command)
      end

      def raise_output_limit!(command)
        raise @session.build_error(ScriptOutputLimitExceeded,
                                   "script output reached max_script_output_bytes; commands already sent may have executed",
                                   phase: :script, command: command), cause: nil
      end
    end
  end
end
