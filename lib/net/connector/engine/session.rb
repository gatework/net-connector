# frozen_string_literal: true

require_relative "authentication"
require_relative "log"
require_relative "redactor"
require_relative "response_reader"
require_relative "recovery"
require_relative "transports"

module Net
  module Connector
    # 连接状态、传输层和日志的唯一所有者；同一时刻只允许一个操作占用会话。
    class Session
      MAX_ERROR_OUTPUT_BYTES = 4096

      # 读取当前会话配置、自有传输与解析组件，以及连接状态和已知提示符。
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

      # 判断会话状态和传输通道是否仍处于连接状态。
      def connected? = state != :closed && !transport.closed?

      # 读取当前会话已确认的特权状态。
      def privileged? = @privileged

      # 登记当前会话已完成特权认证。
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
        if @operation_owner == [Thread.current, Fiber.current] && !@performing && !@closing
          return perform_locked(phase, &)
        end
        with_session_lock(phase) { perform_locked(phase, &) }
      end

      # 业务操作在多次脚本之间持有租约；只有同一线程和 Fiber 可顺序使用。
      def with_operation(phase)
        with_session_lock(phase, operation: true) do
          result = nil
          @log.with_operation_context(phase) { result = yield }
        rescue Error => error
          raise unless result.is_a?(Result)

          # 日志收尾失败不能抹去已完成的设备步骤，也不能覆盖原业务错误。
          Result.new(steps: result.steps, config: result.config,
                     error: result.error || normalize_error(error, phase: phase))
        end
      end

      # 文件业务必须先取得路径锁，再调用会话；不能持有会话租约去等待另一个备份者。
      def assert_path_lock_order!(phase)
        return unless @lock.locked?

        raise build_error(SessionBusy, "backup path ownership must be acquired before a session operation", phase: phase), cause: nil
      end

      # 同一操作所有者可在命令结束后关闭借用会话，关闭回调及其他执行者仍不得重入。
      def close
        if @operation_owner == [Thread.current, Fiber.current] && !@performing && !@closing
          failure = nil
          begin
            @closing = true
            close_resources
          rescue Exception => error # rubocop:disable Lint/RescueException -- 状态收尾的二次取消不能覆盖原始关闭故障。
            failure = error
            raise
          ensure
            begin
              Thread.handle_interrupt(Exception => :never) { @closing = false }
            rescue Exception => error # rubocop:disable Lint/RescueException -- 先清除重入标记，再交付原始取消或收尾取消。
              Thread.handle_interrupt(Exception => :never) { @closing = false }
              error = failure || error
              raise error, cause: error.cause
            end
          end
        else
          with_session_lock(:close, busy_message: "cannot close a session owned by another operation") { close_resources }
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
      def with_command_redaction(command, reuse: false)
        redactor.with_scope(reuse: reuse) do
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
          rescue Exception # rubocop:disable Lint/RescueException -- 交互失败或中断后仍关闭会话，保留本次原始异常。
            failed = true
            raise
          ensure
            failed ? close_preserving_failure : close_resources
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

      # 返回对象的安全摘要，不展开正文或认证凭据。
      def inspect = "#<#{self.class} state=#{state} host=#{configuration.host.inspect}>"

      private

      # 锁取得与所有权登记不可拆开；只在交接及释放窗口延迟取消，业务等待仍可中断。
      def with_session_lock(phase, operation: false, busy_message: "session already belongs to another operation")
        acquired = false
        failure = nil
        begin
          Thread.handle_interrupt(Exception => :never) do
            acquired = @lock.try_lock
            @operation_owner = [Thread.current, Fiber.current] if acquired && operation
          end
          unless acquired
            raise build_error(SessionBusy, busy_message, phase: phase), cause: nil
          end

          yield
        rescue Exception => error # rubocop:disable Lint/RescueException -- 解锁期间的二次取消不能覆盖原业务故障。
          failure = error
          raise
        ensure
          if acquired
            begin
              Thread.handle_interrupt(Exception => :never) do
                @operation_owner = nil if operation
                @lock.unlock
              end
            rescue Exception => error # rubocop:disable Lint/RescueException -- 完成释放后再交付取消，并避免原故障形成 cause 环。
              error = failure || error
              raise error, cause: error.cause
            end
          end
        end
      end

      # 一次操作从连接到结果处理始终持锁；异常或 throw 中断都关闭未完成会话。
      def perform_locked(phase)
        completed = false
        failure = nil
        begin
          @performing = true
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
        rescue Exception => error # rubocop:disable Lint/RescueException -- 中断先释放传输资源，再继续向外传播。
          failure = error
          close_preserving_failure
          raise
        ensure
          finish_perform(completed, failure)
        end
      end

      # 资源查询和关闭仍可取消；不论它们如何退出，都先清除执行标记再交付首个故障。
      def finish_perform(completed, failure)
        begin
          # throw/catch 也会离开此块；对话未完成时必须关闭连接，不能把
          # 半途的设备提示符误当成下一条命令的响应。
          close_preserving_failure unless completed || !connected?
          connected = connected?
        rescue Exception => error # rubocop:disable Lint/RescueException -- 收尾取消不能覆盖已记录的操作故障。
          failure ||= error
        ensure
          begin
            Thread.handle_interrupt(Exception => :never) do
              @state = :ready if connected
              @performing = false
            end
          rescue Exception => error # rubocop:disable Lint/RescueException -- 状态登记完成后才交付二次取消。
            failure ||= error
          end
          raise failure, cause: failure.cause if failure
        end
      end

      # 在命令日志范围内执行读写，记录完成或失败但不重复发送命令。
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

      # 将单调时钟差转换为毫秒，用于事件耗时展示。
      def elapsed_ms(started) = ((Expect.monotonic - started) * 1000).round

      # 记录脚本完成状态及步骤，已执行命令的证据不因诊断失败而消失。
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
          cleaned = close_preserving_failure
          replacement = cleaned && !attempted_recovery ? @recovery.recover(failure, transport) : nil
          if replacement
            @transport = replacement
            attempted_recovery = true
            retry
          end
          raise failure, cause: nil
        end
      end

      # 执行一次登录并记录耗时及结果，恢复策略由外层决定。
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
        rescue Exception # rubocop:disable Lint/RescueException -- 传输关闭失败或中断后仍须尝试关闭日志。
          failed = true
          raise
        ensure
          begin
            @log.close
          rescue Exception # rubocop:disable Lint/RescueException -- 日志收尾不能覆盖传输关闭的首个失败。
            raise unless failed
          end
        end
        nil
      rescue => error
        raise normalize_error(error, phase: :close), cause: nil
      end

      # 清理结果决定能否移交传输所有权；失败仍保留原操作异常与待清理资源。
      def close_preserving_failure
        close_resources
        true
      rescue Exception # rubocop:disable Lint/RescueException -- 原操作失败时，清理故障或中断均不得覆盖它。
        # 所有清理路径完成后，原始操作异常仍然是权威结果。
        false
      end
    end
  end
end
