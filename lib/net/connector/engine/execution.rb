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
        @output_bytes = 0
        @output_limit = session.configuration.max_script_output_bytes
        @sensitive = false
      end

      # 汇总实际执行的命令及交互，包括批次准备和厂商追加查询。
      def sensitive? = @sensitive

      # 依次准备、执行和记录脚本命令；失败时保留已完成步骤并统一抛错。
      def execute_script(script)
        script.each do |original|
          @session.with_command_redaction(original) do
            @current_command = original
            command = @prepare_command.call(original, self)
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
            check_output_budget!(@last_query_command, completed: true)
          rescue => error
            raise @session.normalize_error(error, phase: :script, command: @current_command), cause: nil
          end
        end
        check_output_budget!(@last_query_command, completed: true)
        Result.new(steps: steps)
      end

      # 厂商后续查询复用同一信道和错误处理，不开启新的批处理。
      def execute_command(command)
        command = Command.new(command) unless command.is_a?(Command)
        check_output_budget!(command, completed: false)
        prompt = @prompt&.call(command)
        # 提示符回调也可能追加查询，实际发送前重新检查它消耗的预算。
        check_output_budget!(command, completed: false) if @prompt
        response = @session.execute_command(command, timeout: @command_timeout, prompt: prompt) do
          # 必须在 Session 恢复命令词表前读取；最终处理只能继承敏感性，不长期保留秘密。
          @sensitive ||= @session.redactor.sensitive?
        end
        @last_query_command = command
        @output_bytes += response.raw.bytesize
        # 主命令先记录完整步骤，再检查超额；追加查询同样计入预算，但不改变原 steps 结构。
        yield response if block_given?
        check_output_budget!(command, completed: true)
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
      def check_output_budget!(command, completed:)
        return unless @output_limit && (completed ? @output_bytes > @output_limit : @output_bytes >= @output_limit)

        raise @session.build_error(ScriptOutputLimitExceeded,
                             "script output reached max_script_output_bytes; commands already sent may have executed",
                             phase: :script, command: command), cause: nil
      end
    end
  end
end
