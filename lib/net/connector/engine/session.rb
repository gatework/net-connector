# frozen_string_literal: true

require "English"
require_relative "authentication"
require_relative "log"
require_relative "recovery"
require_relative "transport"

module Net
  module Connector
    # 连接状态、传输层和日志的唯一所有者；同一时刻只允许一个操作占用会话。
    class Session
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

      # 判断会话状态和传输层是否都表明连接仍然有效。
      def connected? = state != :closed && !transport.closed?

      # 返回当前是否已经进入特权模式。
      def privileged? = @privileged

      # 标记当前会话已进入特权模式。
      def mark_privileged! = @privileged = true

      # 记录脚本之外的业务结果，例如设备报告的 TFTP 上传状态。
      def log_event(name, **fields) = @log.event(name, **fields)

      # 在会话锁内建立连接。
      def connect
        perform(:connect) { self }
      end

      # 锁覆盖完整操作而不是单次写入，保证批处理命令不会交错。
      def perform(phase)
        if @operation_owner == [Thread.current, Fiber.current] && !@performing
          return perform_locked(phase) { yield }
        end
        unless @lock.try_lock
          raise error(SessionBusy, "session already belongs to another operation", phase: phase), cause: nil
        end

        begin
          perform_locked(phase) { yield }
        ensure
          @lock.unlock
        end
      end

      # 业务操作在多次脚本之间持有租约；只有同一线程和 Fiber 可顺序使用。
      def with_operation(phase)
        unless @lock.try_lock
          raise error(SessionBusy, "session already belongs to another operation", phase: phase), cause: nil
        end
        @operation_owner = [Thread.current, Fiber.current]
        begin
          yield
        ensure
          @operation_owner = nil
          @lock.unlock
        end
      end

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

      private :perform_locked

      # 独占关闭会话；已有操作占用时返回会话繁忙错误。
      def close
        unless @lock.try_lock
          raise error(SessionBusy, "cannot close a session owned by another operation", phase: :close), cause: nil
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
          raise error(UnsupportedOperation, "privilege authentication is not supported", phase: :enable), cause: nil
        end

        @privileged = false
        response = @log.pause { @authentication.enable(command, prompt) }
        @prompt = response.prompt
        @privileged = true
        response
      end

      # 命令准备、交换、后处理及回调共用一份临时词表，退出时一并清除。
      def command_scope(command)
        redactor.scope do
          protect_command(command)
          yield
        end
      end

      # 复用完整命令的脱敏范围；厂商后续查询产生的秘密保留到外层回调结束。
      def exchange(command, timeout:, prompt: nil)
        redactor.scope(reuse: true) do
          protect_command(command)
          started = Expect.monotonic
          @log.event("command_start", text: command.sensitive? ? "[REDACTED]" : command.text)
          sensitive_dialogue = [*command.interactions, *@dialogue.command_interactions].any?(&:sensitive?)
          @log.event("device_output", level: :debug) if @log.detailed? && !command.sensitive? && !sensitive_dialogue
          response = exchange_command(command, timeout: timeout, prompt: prompt)
          @log.response_output(response.raw) unless command.sensitive? || sensitive_dialogue
          @log.event("command_complete", status: "response_received")
          @log.event("command_detail", level: :debug,
                     duration_ms: ((Expect.monotonic - started) * 1000).round,
                     response_bytes: response.raw.bytesize)
          response
        rescue => error
          failure = normalize_error(error, phase: :command, command: command)
          @log.event("command_complete", level: :error, status: "failed",
                     error: failure.class.name, message: failure.message)
          raise failure, cause: nil
        end
      end

      # 在用户钩子运行前标记敏感上下文，动态交互尚未返回时也能保护其异常。
      def protect_command(command)
        if command.sensitive? || [*command.interactions, *@dialogue.command_interactions].any?(&:sensitive?)
          redactor.sensitive!
        end
        redactor.remember(command.text) if command.sensitive?
      end

      private :protect_command

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
            raise error(DeviceError, diagnostic, phase: :command, command: command, output: response.raw), cause: nil
          end

          response
        end
        if command.sensitive? || interactions.any?(&:sensitive?)
          @log.pause(&operation)
        else
          operation.call
        end
      end

      private :exchange_command

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
      def error(klass, message, phase:, command: nil, output: "".b, underlying: nil, **context)
        sensitive = redactor.sensitive? || command&.sensitive?
        message = safe_error_text(message, sensitive: sensitive)
        output = safe_error_text(output, sensitive: sensitive)
        klass.new(message, host: configuration.host, phase: phase,
                  command: command && (command.sensitive? ? "[REDACTED]" : redactor.call(command.text)),
                  source: command&.source, line: command&.line,
                  output: output.byteslice(-4096, 4096) || output,
                  underlying: underlying && UnderlyingError.new(underlying, redactor, sensitive: sensitive), **context)
      end

      # 将底层异常映射为连接、传输、超时或内部错误，并保留安全上下文。
      def normalize_error(exception, phase:, command: nil)
        if exception.is_a?(Error)
          sensitive = redactor.sensitive? || command&.sensitive?
          failed_command = exception.command || command&.text
          if command&.sensitive? || (sensitive && exception.command && exception.command != command&.text)
            failed_command = "[REDACTED]"
          end
          message = safe_error_text(exception.message, sensitive: sensitive)
          output = safe_error_text(exception.output, sensitive: sensitive)
          return exception.class.new(
            message, code: exception.code,
            host: exception.host || configuration.host, phase: exception.phase || phase,
            command: failed_command && redactor.call(failed_command),
            source: exception.source || command&.source, line: exception.line || command&.line,
            output: output.byteslice(-4096, 4096) || output,
            underlying: exception.underlying && UnderlyingError.new(exception.underlying, redactor, sensitive: sensitive)
          )
        end

        klass = case exception
                when Expect::WriteTimeout then WriteTimeout
                when IOError, SystemCallError, Expect::SpawnError then TransportError
                else InternalError
                end
        error(klass, "#{phase} failed: #{exception.class}", phase: phase, command: command, underlying: exception)
      end

      # 敏感上下文的任意异常和设备输出可能只包含局部秘密，保留类型和错误码诊断。
      def safe_error_text(text, sensitive:)
        sensitive && !text.to_s.empty? ? "[REDACTED]".b : redactor.call(text)
      end

      private :safe_error_text

      # 返回不包含凭据的会话状态摘要。
      def inspect = "#<#{self.class} state=#{state} host=#{configuration.host.inspect}>"

      private

      # 建立传输并登录；失败时最多执行一次连接级恢复，然后重试登录。
      def connect_session
        attempted_recovery = false
        begin
          @state = :connecting
          redactor.reset
          @log.open(transport)
          @log.event("connect", host: configuration.host, username: configuration.username,
                     protocol: transport.respond_to?(:protocol) ? transport.protocol : configuration.protocol)
          transport.open
          @state = :authenticating
          @log.event("login_start", level: :debug)
          response = @authentication.login
          safe_response = Response.new(raw: redactor.call(response.raw), output: redactor.call(response.output),
                                       prompt: response.prompt)
          @prompt = response.prompt
          @after_login.call(self, safe_response)
          @log.authentication_output(response.raw)
          @log.event("login_complete", status: "ok", prompt: response.prompt)
          @log.attach
          @state = :ready
        rescue => error
          phase = (@state == :connecting) ? :connect : :login
          failure = normalize_error(error, phase: phase)
          @log.event(phase == :connect ? "connect_failed" : "login_complete", level: :error,
                     status: "failed", error: failure.class.name, message: failure.message, phase: phase)
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
