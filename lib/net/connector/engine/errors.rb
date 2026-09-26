# frozen_string_literal: true

module Net
  module Connector
    # 操作错误携带已脱敏上下文；原始配置只存在于明确的结果或日志中。
    class Error < StandardError
      attr_reader :code, :host, :phase, :command, :output, :source, :line, :underlying

      # 保存错误阶段、命令和输出尾部，并为缺省错误类生成稳定错误码。
      def initialize(message, code: nil, host: nil, phase: nil, command: nil, output: "".b,
                     source: nil, line: nil, underlying: nil)
        super(message)
        @code = code || self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym
        @host = host
        @phase = phase
        @command = command
        @output = output.freeze
        @source = source
        @line = line
        @underlying = underlying
      end

      # 返回不展开命令和输出的错误摘要。
      def inspect = "#<#{self.class} code=#{code.inspect} phase=#{phase.inspect} host=#{host.inspect}>"
    end

    class ConnectionError < Error; end

    class AuthenticationError < ConnectionError; end

    class LoginTimeout < AuthenticationError; end

    class CommandTimeout < Error; end

    class WriteTimeout < Error; end

    class PromptError < Error; end

    class ConnectionClosed < ConnectionError; end

    class TransportError < ConnectionError; end

    class DeviceError < Error; end

    class ScriptError < Error; end

    class InternalError < Error; end

    class OutputLimitExceeded < Error; end

    class SessionBusy < Error; end

    class UnsupportedOperation < Error; end

    class LogError < Error; end

    class ParsingError < Error; end

    # 安全保存底层异常，不保留包含凭据的原始消息。
    class UnderlyingError
      attr_reader :type, :message, :backtrace

      # 保存脱敏后的异常类型、消息和调用栈。
      def initialize(error, redactor, sensitive: false)
        @type = error.is_a?(UnderlyingError) ? error.type : error.class.name
        @message = (sensitive ? "[REDACTED]" : redactor.call(error.message)).freeze
        @backtrace = (sensitive ? [] : Array(error.backtrace).map { |line| redactor.call(line).freeze }).freeze
        freeze
      end

      # 返回底层异常类型摘要。
      def inspect = "#<#{self.class} type=#{type}>"
    end

    # 每个会话独立保存脱敏词，包括配置凭据和动态认证响应。
    class Redactor
      # 保存初始凭据，并建立第一版脱敏词表。
      def initialize(*secrets)
        @configured = secrets.compact.map(&:b).map(&:freeze).freeze
        reset
      end

      # 重置动态词表，同时保留配置中的固定凭据。
      def reset
        @secrets = []
        @pattern = nil
        @scoped = false
        @sensitive = false
        @configured.each { |secret| remember(secret) }
      end

      # 临时命令响应在错误归一化期间保留，离开作用域后不进入长期会话。
      def scope(reuse: false)
        return yield if reuse && @scoped

        previous = @secrets
        previous_pattern = @pattern
        previous_scoped = @scoped
        previous_sensitive = @sensitive
        @secrets = previous.dup
        @scoped = true
        begin
          yield
        ensure
          @secrets = previous
          @pattern = previous_pattern
          @scoped = previous_scoped
          @sensitive = previous_sensitive
        end
      end

      # 敏感命令和交互的异常可能只引用秘密的一部分，不能只依赖完整词匹配。
      def sensitive! = @sensitive = true

      # 判断当前脱敏范围是否包含敏感交互。
      def sensitive? = @sensitive

      # 记住新的敏感字节，并按长度排序避免短词先匹配。
      def remember(secret)
        return if secret.nil? || secret.empty?

        bytes = secret.b
        return if @secrets.include?(bytes)

        @secrets << bytes.freeze
        @secrets.sort_by! { |value| -value.bytesize }
        @pattern = nil
      end

      # 保留可能跨下一分片的尾部；完整匹配始终作为整体脱敏。
      def stream_chunk(bytes, final: false)
        return [call(bytes), "".b] if final || @secrets.empty?

        retained = [@secrets.first.bytesize, "[REDACTED]".bytesize].max - 1
        boundary = [bytes.bytesize - retained, 0].max
        matches(bytes).each do |start, finish|
          if start < boundary && finish > boundary
            boundary = start
            break
          end
        end
        [call(bytes.byteslice(0, boundary)), bytes.byteslice(boundary..)]
      end

      # 单次扫描替换所有敏感词，并保留已有脱敏标记。
      def call(text)
        text = text.to_s.b
        return text if @secrets.empty?

        output = +"".b
        offset = 0
        matches(text).each do |start, finish|
          output << text.byteslice(offset, start - offset) << "[REDACTED]"
          offset = finish
        end
        output << text.byteslice(offset..)
      end

      # 返回脱敏器类型摘要。
      def inspect = "#<#{self.class}>"

      private

      # 前瞻保留重叠匹配；跨标记边界的真实秘密不能被已有标记遮蔽。
      def pattern
        @pattern ||= /(?=(#{Regexp.union((@secrets + ["[REDACTED]"]).uniq.sort_by { |secret| -secret.bytesize })}))/n
      end

      # 合并重叠的秘密匹配区间，防止替换顺序露出部分凭据。
      def matches(text)
        ranges = []
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          start, finish = match.begin(1), match.end(1)
          if ranges.last && start < ranges.last.last
            ranges.last[1] = [ranges.last.last, finish].max
          else
            ranges << [start, finish]
          end
        end
        ranges
      end
    end
  end
end
