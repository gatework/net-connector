# frozen_string_literal: true

require "fileutils"
require "logger"
require_relative "terminal_renderer"
require_relative "log_messages"
require_relative "errors"

module Net
  module Connector
    # 单个设备会话的日志，按级别控制是否包含完整回显。
    class Log
      LEVELS = { debug: ::Logger::DEBUG, info: ::Logger::INFO,
                 warn: ::Logger::WARN, error: ::Logger::ERROR }.freeze

      # 保存日志配置和敏感信息脱敏器。
      def initialize(configuration, redactor:)
        @configuration = configuration
        @redactor = redactor
      end

      # 为会话打开日志文件或应用日志器。
      def open(transport)
        @transport = transport
        @io = open_file(@configuration.log_file) if @configuration.log_file
        @output = RedactingWriter.new(@io, @redactor) if @io
        if @configuration.log_format == :raw
          @writer = @output
        elsif @io || @configuration.logger
          base = @configuration.logger || ::Logger.new(@io)
          unless @configuration.logger
            base.formatter = proc do |severity, time, _program, message|
              "[#{time.getlocal.strftime("%Y-%m-%d %H:%M:%S %:z")}] #{severity} #{message}\n"
            end
          end
          # 前缀直接写入消息，不克隆或修改调用方注入的日志器。
          @logger = base
          @event_level = [base.level, LEVELS.fetch(@configuration.log_level)].max
          @tag = "[host=#{@configuration.host}] "
          if @io && @configuration.log_level == :debug
            @writer = TerminalRenderer.new(@output, max_line_bytes: @configuration.max_output_bytes)
          end
        end
        @line_open = false
      rescue => error
        close_preserving_error
        raise failure("unable to open session log", error), cause: nil
      end

      # 将终端回显接入当前会话日志。
      def attach
        return unless @transport && @writer

        @transport.log_output = self
        @attached = true
      end

      # 判断当前日志级别是否需要完整设备回显。
      def detailed? = @configuration.log_level == :debug && !!(@writer || @logger)

      # 按日志级别写入已脱敏的业务事件。
      def event(name, level: :info, **fields)
        return unless @logger

        values = fields.transform_values do |value|
          value.is_a?(String) ? @redactor.call(value).scrub.gsub(/[[:cntrl:]]+/, " ").strip : value
        end
        safe_name = @redactor.call(name.to_s).scrub.gsub(/[[:cntrl:]]+/, " ").strip
        finish_line
        @logger.public_send(level, "#{@tag}#{LogMessages.format(safe_name, values)}") if LEVELS.fetch(level) >= @event_level
      rescue Error
        raise
      rescue => error
        raise failure("unable to write session event", error), cause: nil
      end

      # 登录完成并收集动态口令后，再记录已脱敏的认证回显。
      def authentication_output(bytes)
        return unless detailed?

        event("login_output", level: :debug)
        if @writer
          write(@redactor.call(bytes))
          flush
        else
          response_output(bytes)
        end
      end

      # 应用注入的日志器没有终端写入器，改由日志器记录完整回显。
      def response_output(bytes)
        return unless detailed? && !@writer && !@redactor.output_sensitive?

        @redactor.call(TerminalRenderer.render(@redactor.call(bytes))).each_line do |line|
          @logger.debug("#{@tag}  #{line.chomp}") if ::Logger::DEBUG >= @event_level
        end
      rescue Error
        raise
      rescue => error
        raise failure("unable to write device output", error), cause: nil
      end

      # 向终端日志写入已处理的回显字节。
      def write(bytes)
        return unless @writer

        @writer.write(bytes)
        @line_open = !bytes.end_with?("\n") unless bytes.empty?
      rescue Error
        raise
      rescue => error
        raise failure("unable to write session log", error), cause: nil
      end

      # 刷新日志缓冲区。
      def flush
        @writer&.flush
        @io&.flush
      rescue Error
        raise
      rescue => error
        raise failure("unable to flush session log", error), cause: nil
      end

      # 执行代码块期间暂停自动记录传输回显。
      def pause
        finish_output
        @transport.log_output = nil if @transport
        yield
      ensure
        @transport.log_output = self if @transport && @writer && @attached
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
            @writer = @output = @logger = @io = @transport = @tag = @event_level = nil
            @attached = false
          end
        end
      rescue Error
        raise
      rescue => error
        raise failure("unable to close session log", error), cause: nil
      end

      private

      # 结束未换行的回显，保持事件独占一行。
      def finish_line
        return unless @writer

        finish_output
        @io.write("\n") if @line_open
        @line_open = false
      end

      # 先完成终端渲染，再写出脱敏流的最后几个字节。
      def finish_output
        @writer.finish if @writer.respond_to?(:finish)
        @output&.finish unless @output.equal?(@writer)
      end

      # 文件写入边界保留短尾部，避免分片或终端控制符拼出明文凭据。
      class RedactingWriter
        # 保存目标与作用域；每个日志目标独占 expect-pty 的过滤流。
        def initialize(target, redactor)
          @target = target
          @redactor = redactor
          @filter = redactor.stream
        end

        # 写入已确认安全的前缀，暂存可能与下一分片组成秘密的尾部。
        def write(bytes)
          @filter.patterns = @redactor.patterns
          @target.write(@filter.append(bytes.b))
          bytes.bytesize
        end

        # 刷新目标流，仍不提前写出待判断的尾部。
        def flush = @target.flush

        # 在日志结束时脱敏并写出剩余尾部。
        def finish
          @filter.patterns = @redactor.patterns
          # 保留旧日志的完整词匹配契约；配置正文由 Session 的敏感范围直接隔离。
          @target.write(@filter.finish(partial: false))
          flush
        end
      end

      private_constant :RedactingWriter

      # 以私有权限打开设备日志文件。
      def open_file(path)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        file = File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW, 0o600)
        begin
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
      def failure(message, error)
        LogError.new(message, phase: :logging,
                     underlying: UnderlyingError.new(error, @redactor, sensitive: @redactor.sensitive?))
      end
    end
  end
end
