# frozen_string_literal: true

require_relative "errors"
require_relative "terminal_renderer"
require "expect/pty"

module Net
  module Connector
    # 一组提示与响应规则；可调用响应支持一次性密码等动态挑战。
    class Interaction
      attr_reader :pattern, :limit

      # 校验提示模式、响应类型和次数限制，然后冻结规则定义。
      def initialize(pattern, response, sensitive: false, limit: nil, capture: true)
        unless pattern.is_a?(Regexp) && !pattern.match?("")
          raise ArgumentError, "interaction pattern must be a nonempty Regexp"
        end
        unless response.is_a?(String) || response.respond_to?(:call)
          raise ArgumentError, "response must be a String or callable"
        end
        valid_limit = limit.nil? || (limit.is_a?(Integer) && limit.positive?)
        unless valid_limit
          raise ArgumentError, "limit must be positive or nil"
        end
        unless [true, false].include?(sensitive) && [true, false].include?(capture)
          raise ArgumentError, "sensitive and capture must be true or false"
        end

        @pattern = pattern
        @response = response.is_a?(String) ? response.dup.freeze : response
        @sensitive = sensitive
        @limit = limit
        @capture = capture
        freeze
      end

      # 根据当前提示计算响应文本或调用动态响应函数。
      def response(prompt) = @response.respond_to?(:call) ? @response.call(prompt) : @response

      # 判断响应是否需要从日志和错误上下文中脱敏。
      def sensitive? = @sensitive

      # 判断提示文本是否应保留在响应输出中。
      def capture? = @capture

      # 返回不包含响应内容的规则摘要。
      def inspect = "#<#{self.class} sensitive=#{sensitive?}>"

      # 将普通交互转换为一次性的敏感挑战。
      def challenge
        self.class.new(pattern, @response, sensitive: true, limit: limit || 1, capture: false)
      end
    end

    # 每台设备一份不可变对话语法，由厂商方法组装而不是合并默认值。
    class Dialogue
      attr_reader :login_prompt, :command_prompt, :password_prompt, :username_prompt, :enable_prompt,
                  :authentication_errors, :command_errors, :login_interactions, :command_interactions

      # 校验提示和交互列表，并冻结整套设备对话语法。
      def initialize(login_prompt:, command_prompt:, password_prompt:, username_prompt:, enable_prompt:,
                     authentication_errors:, command_errors:, login_interactions:, command_interactions:)
        @login_prompt = login_prompt
        @command_prompt = command_prompt
        @password_prompt = password_prompt
        @username_prompt = username_prompt
        @enable_prompt = enable_prompt
        [login_prompt, command_prompt, password_prompt, username_prompt, enable_prompt].each do |pattern|
          raise ArgumentError, "prompt must be a nonempty Regexp" unless pattern.is_a?(Regexp) && !pattern.match?("")
        end
        @authentication_errors = authentication_errors.freeze
        @command_errors = command_errors.freeze
        @login_interactions = login_interactions.freeze
        @command_interactions = command_interactions.freeze
        freeze
      end

      # 从命令输出中返回包含错误模式的诊断行，而不是光标或此前全部输出。
      def diagnostic(output)
        return if command_errors.empty?

        # 先保留被回车覆写的失败，再识别颜色或退格处理后的可见诊断。
        raw = output.gsub(/\r(?!\n)/, "\n")
        diagnostic_line(raw) || (diagnostic_line(TerminalRenderer.render(output)) if output.match?(/[\e\b]/))
      end

      private

      def diagnostic_line(output)
        match = command_errors.lazy.filter_map { |pattern| pattern.match(output) }.first
        return unless match

        start = match.begin(0).positive? ? output.rindex(/[\r\n]/, match.begin(0) - 1) : nil
        start = start ? start + 1 : 0
        finish = output.index(/[\r\n]/, match.end(0)) || output.bytesize
        output.byteslice(start, finish - start).strip
      end
    end

    # 在厂商清理前保留原始字节，供诊断和日志使用。
    class Response
      attr_reader :raw, :output, :prompt

      # 保存原始响应、清理后输出和命令结束提示，并冻结三者。
      def initialize(raw:, output:, prompt:)
        @raw = raw.freeze
        @output = output.freeze
        @prompt = prompt.freeze
        freeze
      end

      # 返回响应大小摘要，不展开原始内容。
      def inspect = "#<#{self.class} bytes=#{raw.bytesize}>"
    end

    # 在传输层上执行有界对话；收到字节或分页标记不会重置截止时间。
    class ResponseReader
      # 保存会话引用，以便读取器使用传输、配置和脱敏上下文。
      def initialize(session)
        @session = session
      end

      # 读取到结束提示、失败模式或超时，并处理交互响应和输出上限。
      def read(prompt:, interactions:, phase:, timeout: nil, deadline: nil, command: nil, failures: {})
        deadline ||= Expect.monotonic + timeout
        patterns = [*failures.keys, *interactions.map(&:pattern), prompt]
        raw = []
        output = []
        counts = Hash.new(0)
        bytes = 0
        loop do
          event = @session.transport.read(patterns, timeout: [deadline - Expect.monotonic, 0].max)
          raw << event.before unless event.before.empty?
          output << event.before unless event.before.empty?
          bytes += event.before.bytesize + event.match.bytesize
          if bytes > @session.configuration.max_output_bytes
            raise @session.error(OutputLimitExceeded, "device output exceeded max_output_bytes",
                                 phase: phase, command: command, output: (raw + [event.match]).join), cause: nil
          end
          raise read_error(event, phase, command, raw.join), cause: nil unless event.matched?

          if event.index == patterns.size
            raw << event.match
            output << event.match
          elsif event.index == patterns.size - 1
            if event.match.empty?
              raise @session.error(PromptError, "prompt pattern did not consume any output",
                                   phase: phase, command: command, output: raw.join), cause: nil
            end

            raw << event.match
            output << event.match
            raw_text = raw.join
            return Response.new(raw: raw_text, output: (output == raw) ? raw_text : output.join, prompt: event.match)
          elsif event.index < failures.size
            klass, code = failures.values.fetch(event.index)
            raise @session.error(klass, "device connection failed (#{code})", phase: phase,
                                 code: code, command: command), cause: nil
          else
            reply = interactions.fetch(event.index - failures.size)
            raw << event.match
            output << event.match if reply.capture?
            counts[reply] += 1
            if event.match.empty? || (reply.limit && counts[reply] > reply.limit)
              raise interaction_error("response rejected or repeated", phase, command), cause: nil
            end

            value = interaction_response(reply, event.match, phase, command)
            raise interaction_error("response unavailable", phase, command), cause: nil unless value.is_a?(String)

            @session.redactor.remember(value.chomp) if reply.sensitive?
            @session.write(value, deadline: deadline, phase: phase, command: command)
          end
          next if Expect.monotonic < deadline

          raise read_error(nil, phase, command, raw.join), cause: nil
        end
      end

      private

      # 动态口令尚未返回时无法加入词表，须在敏感范围内先归一化回调异常。
      # 成功后由调用方登记响应，临时敏感标记不会影响后续普通命令的诊断。
      def interaction_response(reply, prompt, phase, command)
        return reply.response(prompt) unless reply.sensitive?

        @session.redactor.scope(reuse: true) do
          @session.redactor.sensitive!
          reply.response(prompt)
        rescue => error
          raise @session.normalize_error(error, phase: phase, command: command), cause: nil
        end
      end

      # 将交互拒绝或响应缺失转换为认证或脚本错误。
      def interaction_error(message, phase, command)
        authenticating = %i[login enable].include?(phase)
        klass = authenticating ? AuthenticationError : ScriptError
        label = authenticating ? "authentication" : "command interaction"
        @session.error(klass, "#{label} #{message}", phase: phase, command: command)
      end

      # 根据 EOF、提示符、阶段和底层异常选择具体读取错误类型。
      def read_error(event, phase, command, output)
        if event&.error.is_a?(Exception)
          return @session.error(TransportError, "transport read failed", phase: phase, command: command,
                                underlying: event.error, output: output)
        end
        klass = if event&.error == :eof
                  ConnectionClosed
                elsif command&.prompt
                  PromptError
                elsif %i[login enable].include?(phase)
                  LoginTimeout
                else
                  CommandTimeout
                end
        @session.error(klass, "device response #{event&.error || :timeout}", phase: phase,
                       command: command, output: output)
      end
    end
  end
end
