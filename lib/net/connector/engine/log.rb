# frozen_string_literal: true

require "fileutils"
require "logger"
require "securerandom"
require_relative "terminal_renderer"
require_relative "log/event"
require_relative "log/formatter"
require_relative "log/stream"
require_relative "errors"
require_relative "error_metadata"

module Net
  module Connector
    # 单个设备会话的日志，按级别控制是否包含完整回显。
    class Log
      LEVELS = { debug: ::Logger::DEBUG, info: ::Logger::INFO,
                 warn: ::Logger::WARN, error: ::Logger::ERROR }.freeze
      CONTEXT_FIELDS = %w[host session_id operation command_id text source line].freeze
      private_constant :CONTEXT_FIELDS

      # 保存日志配置和敏感信息脱敏器。
      def initialize(configuration, redactor:)
        @configuration = configuration
        @redactor = redactor
        @context = {}.freeze
      end

      # 为会话打开日志文件或应用日志器。
      def open(transport)
        @transport = transport
        @session_id = SecureRandom.hex(8).freeze
        @command_sequence = 0
        @io = open_file(@configuration.log_file) if @configuration.log_file
        if @configuration.log_format == :raw
          @writer = @output = RedactingWriter.new(@io, @redactor) if @io
        elsif @io || @configuration.logger
          @logger = @configuration.logger || ::Logger.new(@io, formatter: Formatter.new)
          open_transcript if @io && @configuration.log_level == :debug
        end
      rescue => error
        close_preserving_error
        raise build_error("unable to open session log", error), cause: nil
      end

      # 上下文只在持有会话锁期间使用；收尾必须先于恢复父上下文。
      def with_context(**fields)
        previous = @context
        finish_output
        @context = @context.merge(fields).freeze
        yield
      rescue Exception # rubocop:disable Lint/RescueException -- Preserve only failures propagating from this scope, including interrupts.
        failed = true
        raise
      ensure
        begin
          finish_output
        rescue Error
          raise unless failed
        ensure
          @context = previous
        end
      end

      def with_operation_context(name, &)
        with_context(operation: name || @context[:operation] || :script, &)
      end

      def with_command_context(command, &)
        @command_sequence += 1
        with_context(command_id: @command_sequence, phase: :command,
                     text: command.sensitive? ? "[REDACTED]" : command.text,
                     source: command.source, line: command.line, &)
      end

      # 将终端回显接入当前会话日志。
      def attach
        return unless @transport && @writer

        @transport.log_output = self
        @attached = true
      end

      # 判断当前日志级别是否需要完整设备回显。
      def debug? = @configuration.log_level == :debug && (!!@writer || enabled?(:debug))

      # 按日志级别写入已脱敏的业务事件。
      def log_event(name, level: :info, **fields)
        return unless @logger || @configuration.on_event

        finish_output
        write_event(name, level: level, **fields)
      rescue Error
        raise
      rescue => error
        raise build_error("unable to write session event", error), cause: nil
      end

      # 异常正文由会话先脱敏；类型、错误码和阶段只允许共享词表中的值进入日志。
      def log_failure(name, failure, phase: nil, **fields)
        log_event(name, level: :error, **fields,
                  error: ErrorMetadata.type(failure.class.name) || "StandardError",
                  code: ErrorMetadata.code(failure.code),
                  phase: ErrorMetadata.phase(failure.phase) || ErrorMetadata.phase(phase),
                  message: failure.message)
      rescue Error
        # 原始失败已由调用者保留；诊断通道故障不能替换登录、命令或业务错误。
        nil
      end

      # 用户钩子可能把未登记的配置片段放进事件名、字段名或值；敏感范围统一隐藏。
      def log_custom_event(name, level: :info, **fields)
        if @redactor.sensitive?
          log_event("custom", level: level, details: "[REDACTED]")
        else
          log_event(name, level: level, **fields)
        end
      end

      # 登录完成并收集动态口令后，再记录已脱敏的认证回显。
      def log_authentication_output(bytes)
        return unless debug?

        with_context(phase: :login) do
          log_event("login_output", level: :debug)
          if @writer
            write(@redactor.call(bytes))
            flush
          else
            log_response_output(bytes)
          end
        end
      end

      # 注入日志器与文件回显共用事件格式；两次脱敏覆盖终端控制符拼接。
      def log_response_output(bytes)
        return unless debug? && !@writer && !@redactor.output_sensitive?

        @redactor.call(TerminalRenderer.render(@redactor.call(bytes))).each_line do |line|
          write_event("device_output", level: :debug, output: line.chomp)
        end
      rescue Error
        raise
      rescue => error
        raise build_error("unable to write device output", error), cause: nil
      end

      # 向终端日志写入已处理的回显字节。
      def write(bytes)
        return unless @writer && !@redactor.output_sensitive?

        @writer.write(bytes)
      rescue Error
        raise
      rescue => error
        raise build_error("unable to write session log", error), cause: nil
      end

      # 刷新日志缓冲区。
      def flush
        @writer&.flush
        @io&.flush
      rescue Error
        raise
      rescue => error
        raise build_error("unable to flush session log", error), cause: nil
      end

      # 执行代码块期间暂停自动记录传输回显。
      def pause
        finish_output
        @transport.log_output = nil if @transport
        yield
      rescue Exception # rubocop:disable Lint/RescueException -- Restore attachment without replacing this scope's failure or interruption.
        failed = true
        raise
      ensure
        begin
          @transport.log_output = self if @transport && @writer && @attached
        rescue StandardError
          # 恢复接线仍须尝试，但不能盖掉设备失败或用户中断。
          raise unless failed
        end
      end

      # 断开回显记录并关闭日志资源。
      def close
        begin
          @transport.log_output = nil if @transport
          finish_output
        ensure
          begin
            @io&.close
          ensure
            @writer = @output = @transcript = @logger = @io = @transport = @session_id = nil
            @attached = false
          end
        end
      rescue Error
        raise
      rescue => error
        raise build_error("unable to close session log", error), cause: nil
      end

      private

      # 每次读取调用方的当前阈值，不缓存级别、不改写共享 Logger。
      def enabled?(level)
        LEVELS.fetch(level) >= LEVELS.fetch(@configuration.log_level) &&
          (@configuration.on_event || (@logger && LEVELS.fetch(level) >= @logger.level))
      end

      def write_event(name, level:, **fields)
        return unless enabled?(level)

        values = @context.compact.merge(fields.reject { |key, _| CONTEXT_FIELDS.include?(key.to_s) })
        values = values.merge(host: @configuration.host, session_id: @session_id)
        event = Event.new(name, values, redactor: @redactor)
        @logger.public_send(level, event) if @logger && LEVELS.fetch(level) >= @logger.level
        @configuration.on_event&.call(event)
      end

      def open_transcript
        @transcript = Transcript.new { |line| write_event("device_output", level: :debug, output: line) }
        @output = RedactingWriter.new(@transcript, @redactor)
        @writer = TerminalRenderer.new(@output, max_line_bytes: @configuration.max_output_bytes)
      end

      # 先渲染，再结束过滤流，最后发出半行事件；顺序不能反转。
      def finish_output
        @writer.finish if @writer.respond_to?(:finish)
        @output&.finish unless @output.equal?(@writer)
        @transcript&.finish
      rescue Error
        raise
      rescue => error
        raise build_error("unable to finish session output", error), cause: nil
      end

      # 以私有权限打开设备日志文件。
      def open_file(path)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        file = File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW | File::NONBLOCK, 0o600)
        begin
          # FIFO 的打开不受登录截止时间约束；验证同一个 FD 后才能修改权限或写入。
          raise ArgumentError, "session log must be a regular file" unless file.stat.file?

          file.chmod(0o600)
          file.binmode
          file.write("\n") if file.size.positive? && @configuration.log_format == :text
          file
        rescue Exception # rubocop:disable Lint/RescueException -- Release partially configured files on interrupts too.
          begin
            file.close
          rescue
            # 保留设置失败的原始原因。
          end
          raise
        end
      end

      # 在日志打开失败后尽力释放资源。
      def close_preserving_error
        close
      rescue
        nil
      end

      # 将日志异常包装成统一错误并保留脱敏原因。
      def build_error(message, error)
        LogError.new(message, phase: :logging,
                     underlying: UnderlyingError.new(error, @redactor, sensitive: @redactor.sensitive?))
      end
    end
  end
end
