# frozen_string_literal: true

require_relative "script"
require_relative "result"

module Net
  module Connector
    # 单个脚本的局部状态；执行对象不拥有设备或传输层生命周期。
    class Execution
      # 读取单次脚本的临时上下文和已完成步骤。
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
      def execute_script(script, on_receipt: nil)
        script.each do |original_command|
          @session.with_command_redaction(original_command) do
            @current_command = original_command
            command = @prepare_command.call(original_command, self)
            next if command.nil?

            # 在替代命令发送前固定扩展契约，错误继续指向原脚本位置，不展开非法返回值。
            raise build_error("prepare_command must return a Command or nil") unless command.is_a?(Command)

            @current_command = command
            step = execute_step(command, on_receipt: on_receipt)
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
        # 追加查询的提示符回调先于发送；复用外层词表，令其诊断及后续业务回调都继承敏感边界。
        @session.with_command_redaction(command, reuse: true) do
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
        rescue => error
          raise @session.normalize_error(error, phase: :script, command: command), cause: nil
        end
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

      # 完成回执独立于成功进度；日志、后处理、预算或取消不撤销已收到的响应。
      def execute_step(command, on_receipt:)
        started = Expect.monotonic
        step, failure = nil, nil
        finished = false
        begin
          response = execute_command(command) do |received|
            step = Command::Result.new(command: command, output: received.output, prompt: received.prompt,
                                       duration: Expect.monotonic - started)
            steps << step
          end
          @after_command.call(command, response, self)
          finished = true
          step
        rescue Exception => error # rubocop:disable Lint/RescueException -- 完成事实先交付，原始取消随后继续传播。
          failure = error
          raise
        ensure
          deliver_receipt(step, on_receipt, failure, unwinding: !finished) if step && on_receipt
        end
      end

      # 收据处理不能用自身异常替换此前的设备失败或取消，也不自动重复回调。
      def deliver_receipt(step, callback, failure, unwinding:)
        callback.call(step)
      ensure
        # ensure 覆盖回调内的 throw/kill；不能让二次退出替换外层正在传播的取消。
        if unwinding
          raise failure, cause: failure.cause if failure

          # 仅结束这个回调子方法，让 execute_step 原有的非局部退出继续。
          return # rubocop:disable Lint/EnsureReturn -- 保留调用方正在进行的 throw、return 或线程终止。
        end
      end

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

      # 报告脚本累计输出超限，并明确此前发送的命令可能已经执行。
      def raise_output_limit!(command)
        raise @session.build_error(ScriptOutputLimitExceeded,
                                   "script output reached max_script_output_bytes; commands already sent may have executed",
                                   phase: :script, command: command), cause: nil
      end
    end
  end
end
