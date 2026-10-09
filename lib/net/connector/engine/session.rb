# frozen_string_literal: true

require "English"
require_relative "authentication"
require_relative "log"
require_relative "redactor"
require_relative "response_reader"
require_relative "recovery"
require_relative "transport"

module Net
  module Connector
    # 连接状态、传输层和日志的唯一所有者；同一时刻只允许一个操作占用会话。
    class Session
      MAX_ERROR_OUTPUT_BYTES = 4096

      attr_reader :configuration, :transport, :reader, :redactor, :state, :prompt

      # 创建认证、响应读取、脱敏和日志对象，并把会话置于关闭状态。
      def initialize(configuration:, dialogue:, transport:, recovery:, after_login:)
        @configuration = configuration
        @dialogue = dialogue
        @transport = transport
        @recovery = recovery
        @after_login = after_login
        @redactor = Redactor.new(configuration.password, configuration.enable_password)
        @reader = ResponseReader.new(self)
        @authentication = Authentication.new(self, @dialogue)
        @log = Log.new(configuration, redactor: redactor)
        @state = :closed
        @privileged = false
        @lock = Mutex.new
      end

      def connected? = state != :closed && !transport.closed?

      def privileged? = @privileged

      def mark_privileged! = @privileged = true

      # 记录脚本之外的业务结果，例如设备报告的 TFTP 上传状态。
      def log_event(name, **fields) = @log.log_custom_event(name, **fields)

      # 业务名称贯穿脚本及其钩子，底层命令另外分配独立序号。
      def log_script(operation:, steps:)
        @log.with_operation_context(operation) do
          started = Expect.monotonic
          @log.log_event("operation_start", level: :debug, phase: :script)
          result = yield
        rescue => error
          failure = normalize_error(error, phase: :script)
          log_operation_completion(started, failure, steps: steps.size)
          raise failure, cause: nil
        else
          # 完成事件只发送一次；观察者失败由外层保留业务结果，不再次调用同一观察者。
          log_operation_completion(started, result.is_a?(Result) ? result.error : nil, steps: steps.size)
          result
        end
      end

      # 在会话锁内建立连接。
      def connect
        perform(:connect) { self }
      end

      # 锁覆盖完整操作而不是单次写入，保证批处理命令不会交错。
      def perform(phase, &)
        if @operation_owner == [Thread.current, Fiber.current] && !@performing
          return perform_locked(phase, &)
        end
        unless @lock.try_lock
          raise build_error(SessionBusy, "session already belongs to another operation", phase: phase), cause: nil
        end

        begin
          perform_locked(phase, &)
        ensure
          @lock.unlock
        end
      end

      # 业务操作在多次脚本之间持有租约；只有同一线程和 Fiber 可顺序使用。
      def with_operation(phase)
        unless @lock.try_lock
          raise build_error(SessionBusy, "session already belongs to another operation", phase: phase), cause: nil
        end
        @operation_owner = [Thread.current, Fiber.current]
        result = nil
        begin
          @log.with_operation_context(phase) { result = yield }
        rescue Error => error
          raise unless result.is_a?(Result)

          # 日志收尾失败不能抹去已完成的设备步骤，也不能覆盖原业务错误。
          Result.new(steps: result.steps, config: result.config,
                     error: result.error || normalize_error(error, phase: phase))
        ensure
          @operation_owner = nil
          @lock.unlock
        end
      end

      # 文件业务必须先取得路径锁，再调用会话；不能持有会话租约去等待另一个备份者。
      def assert_path_lock_order!(phase)
        return unless @lock.locked?

        raise build_error(SessionBusy, "backup path ownership must be acquired before a session operation", phase: phase), cause: nil
      end

      # 独占关闭会话；已有操作占用时返回会话繁忙错误。
      def close
        unless @lock.try_lock
          raise build_error(SessionBusy, "cannot close a session owned by another operation", phase: :close), cause: nil
        end

        begin
          close_resources
        ensure
          @lock.unlock
        end
      end

      # 执行特权认证，并更新提示符及特权状态。
      def enable(command, prompt)
        unless command
          raise build_error(UnsupportedOperation, "privilege authentication is not supported", phase: :enable), cause: nil
        end

        @privileged = false
        response = @log.pause { @authentication.enable(command, prompt) }
        @prompt = response.prompt
        @privileged = true
        response
      end

      # 命令准备、交换、后处理及回调共用一份临时词表，退出时一并清除。
      def with_command_redaction(command)
        redactor.with_scope do
          protect_command(command)
          yield
        end
      end

      # 批次准备和最终清理也可能读取配置；在作用域退出前归一化其异常，
      # 防止清理钩子的消息或回溯将已完成步骤中的正文带回诊断通道。
      def with_sensitive_output(enabled)
        return yield unless enabled

        redactor.with_scope do
          redactor.output_sensitive!
          yield
        rescue => error
          raise normalize_error(error, phase: :script), cause: nil
        end
      end

      # 复用完整命令的脱敏范围；厂商后续查询产生的秘密保留到外层回调结束。
      def execute_command(command, timeout:, prompt: nil)
        response = nil
        redactor.with_scope(reuse: true) do
          protect_command(command)
          @log.with_command_context(command) do
            execute_command_with_logging(command, timeout: timeout, prompt: prompt) { |received| response = received }
          end
        ensure
          # 日志失败也要交付已完成响应；失败的敏感探测同样必须在恢复词表前通知执行器。
          yield response if block_given?
        end
      end

      # 按截止时间限制传输写入，并统一包装底层错误。
      def write(bytes, deadline:, phase:, command: nil)
        remaining = [deadline - Expect.monotonic, 0].max
        transport.write(bytes, timeout: [remaining, configuration.write_timeout].min)
      rescue => error
        raise normalize_error(error, phase: phase, command: command), cause: nil
      end

      # 人工交互会结束当前连接，未完成的输入行不能在之后重放。
      def interact(**options)
        perform(:interact) do
          @state = :interacting
          begin
            transport.interact(**options)
          ensure
            $ERROR_INFO ? close_preserving_failure : close_resources
          end
        end
      end

      # 创建带脱敏上下文、阶段、命令和输出尾部的领域错误。
      def build_error(klass, message, phase:, command: nil, output: "".b, underlying: nil, **context)
        sensitive = redactor.sensitive? || command&.sensitive? || command&.output_sensitive?
        message = safe_error_text(message, sensitive: sensitive)
        output = safe_error_text(output, sensitive: sensitive)
        klass.new(message, host: configuration.host, phase: phase,
                  command: command && (command.sensitive? ? "[REDACTED]" : redactor.call(command.text)),
                  source: command&.source, line: command&.line,
                  output: truncate_output(output),
                  underlying: underlying && UnderlyingError.new(underlying, redactor, sensitive: sensitive), **context)
      end

      # 将底层异常映射为连接、传输、超时或内部错误，并保留安全上下文。
      def normalize_error(exception, phase:, command: nil)
        if exception.is_a?(Error)
          sensitive = redactor.sensitive? || command&.sensitive? || command&.output_sensitive?
          failed_command = exception.command || command&.text
          if command&.sensitive? || (sensitive && exception.command && exception.command != command&.text)
            failed_command = "[REDACTED]"
          end
          message = safe_error_text(exception.message, sensitive: sensitive)
          output = safe_error_text(exception.output, sensitive: sensitive)
          return exception.with_diagnostics(
            message: message,
            host: exception.host || configuration.host, phase: exception.phase || phase,
            command: failed_command && redactor.call(failed_command),
            source: exception.source || command&.source, line: exception.line || command&.line,
            output: truncate_output(output),
            underlying: exception.underlying && UnderlyingError.new(exception.underlying, redactor, sensitive: sensitive)
          )
        end

        klass = case exception
                when Expect::WriteTimeout then WriteTimeout
                when IOError, SystemCallError, Expect::SpawnError then TransportError
                else InternalError
                end
        build_error(klass, "#{phase} failed: #{exception.class}", phase: phase, command: command, underlying: exception)
      end

      def inspect = "#<#{self.class} state=#{state} host=#{configuration.host.inspect}>"

      private

      # 一次操作从连接到结果处理始终持锁；异常或 throw 中断都关闭未完成会话。
      def perform_locked(phase)
        @performing = true
        completed = false
        begin
          unless connected?
            close_resources unless state == :closed
            connect_session
          end
          @state = (phase == :connect) ? :ready : :executing
          result = yield
          completed = true
          result
        rescue => error
          failure = normalize_error(error, phase: phase)
          close_preserving_failure
          raise failure, cause: nil
        rescue Exception # rubocop:disable Lint/RescueException -- Interrupts release the transport, then propagate.
          close_preserving_failure
          raise
        ensure
          # throw/catch 也会离开此块；对话未完成时必须关闭连接，不能把
          # 半途的设备提示符误当成下一条命令的响应。
          close_preserving_failure unless completed || !connected?
          @state = :ready if connected?
          @performing = false
        end
      end

      def execute_command_with_logging(command, timeout:, prompt:, &)
        started = Expect.monotonic
        @log.log_event("command_start")
        sensitive_dialogue = [*command.interactions, *@dialogue.command_interactions].any?(&:sensitive?)
        private_output = command.sensitive? || redactor.output_sensitive? || sensitive_dialogue
        @log.log_event("device_output", level: :debug) if @log.debug? && !private_output
        response = exchange_command(command, timeout: timeout, prompt: prompt, &)
        @log.log_response_output(response.raw) unless private_output
        details = { duration_ms: elapsed_ms(started), response_bytes: response.raw.bytesize }
        @log.log_event("command_complete", status: "response_received", **details)
        response
      rescue => error
        failure = normalize_error(error, phase: :command, command: command)
        @log.log_failure("command_complete", failure, status: "failed", duration_ms: elapsed_ms(started), phase: :command)
        raise failure, cause: nil
      end

      def elapsed_ms(started) = ((Expect.monotonic - started) * 1000).round

      def log_operation_completion(started, failure, steps: nil)
        fields = { status: failure ? "failed" : "completed", duration_ms: elapsed_ms(started), steps: steps,
                   phase: :script }
        if failure
          @log.log_failure("operation_complete", failure, **fields, failed_command: failure.command)
        else
          @log.log_event("operation_complete", **fields)
        end
      end

      # 在用户钩子运行前标记敏感上下文，动态交互尚未返回时也能保护其异常。
      def protect_command(command)
        redactor.output_sensitive! if command.output_sensitive?
        if command.sensitive? || [*command.interactions, *@dialogue.command_interactions].any?(&:sensitive?)
          redactor.sensitive!
        end
        redactor.remember(command.text) if command.sensitive?
      end

      # 写入命令、读取对话、识别设备诊断，并返回响应对象。
      def exchange_command(command, timeout:, prompt: nil)
        deadline = Expect.monotonic + (command.timeout || timeout)
        interactions = [*command.interactions, *@dialogue.command_interactions]
        operation = lambda do
          write("#{command.text}\n", deadline: deadline, phase: :command, command: command)
          response = reader.read(prompt: command.prompt || prompt || @dialogue.command_prompt,
                                 interactions: interactions,
                                 deadline: deadline, phase: :command, command: command)
          @prompt = response.prompt
          if (diagnostic = @dialogue.diagnostic(response.raw))
            raise build_error(DeviceError, diagnostic, phase: :command, command: command, output: response.raw), cause: nil
          end

          # 恢复敏感命令的日志接线也可能失败；在离开暂停范围前保存完成事实。
          yield response
          response
        end
        if command.sensitive? || redactor.output_sensitive? || interactions.any?(&:sensitive?)
          @log.pause(&operation)
        else
          operation.call
        end
      end

      # 敏感上下文的任意异常和设备输出可能只包含局部秘密，保留类型和错误码诊断。
      def safe_error_text(text, sensitive:)
        sensitive && !text.to_s.empty? ? "[REDACTED]".b : redactor.call(text)
      end

      # 必须先脱敏再截取尾部，避免截断凭据后逃过完整词匹配。
      def truncate_output(text)
        text.byteslice(-MAX_ERROR_OUTPUT_BYTES, MAX_ERROR_OUTPUT_BYTES) || text
      end

      # 建立传输并登录；失败时最多执行一次连接级恢复，然后重试登录。
      def connect_session
        attempted_recovery = false
        begin
          @state = :connecting
          started = Expect.monotonic
          login_once(started)
        rescue => error
          phase = (@state == :connecting) ? :connect : :login
          failure = normalize_error(error, phase: phase)
          @log.log_failure(phase == :connect ? "connect_failed" : "login_complete", failure,
                           status: "failed", phase: phase, duration_ms: elapsed_ms(started))
          close_preserving_failure
          replacement = attempted_recovery ? nil : @recovery.recover(failure, transport)
          if replacement
            @transport = replacement
            attempted_recovery = true
            retry
          end
          raise failure, cause: nil
        end
      end

      def login_once(started)
        redactor.reset
        @log.open(transport)
        @log.log_event("connect", host: configuration.host, username: configuration.username,
                       phase: :connect, protocol: transport.respond_to?(:protocol) ? transport.protocol : configuration.protocol)
        transport.open
        @state = :authenticating
        @log.log_event("login_start", level: :debug, phase: :login)
        response = @authentication.login
        transport.authenticated if transport.respond_to?(:authenticated)
        safe_response = Response.new(raw: redactor.call(response.raw), output: redactor.call(response.output),
                                     prompt: response.prompt)
        @prompt = response.prompt
        @after_login.call(self, safe_response)
        @log.log_authentication_output(response.raw)
        @log.log_event("login_complete", status: "ok", prompt: response.prompt, phase: :login, duration_ms: elapsed_ms(started))
        @log.attach
        @state = :ready
      end

      # 清除会话状态并关闭传输和日志资源。
      def close_resources
        @state = :closed
        @privileged = false
        @prompt = nil
        begin
          transport.close
        ensure
          @log.close
        end
        nil
      rescue => error
        raise normalize_error(error, phase: :close), cause: nil
      end

      # 尝试清理资源但不覆盖原始操作异常。
      def close_preserving_failure
        close_resources
      rescue
        # 所有清理路径完成后，原始操作异常仍然是权威结果。
        nil
      end
    end
  end
end
