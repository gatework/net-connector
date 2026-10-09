# frozen_string_literal: true

require_relative "error_metadata"

module Net
  module Connector
    # 操作错误携带已脱敏上下文；敏感配置正文只存在于明确返回的业务结果中。
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

      # 内置错误保留业务回执，但不复制可能含秘密的原生 cause 和调用栈。
      # 自定义子类重新构造，避免其 message 等方法继续读取未脱敏的私有字段。
      def with_diagnostics(message:, **context)
        context = { code: code, host: host, phase: phase, command: command, output: output,
                    source: source, line: line, underlying: underlying }.merge(context)
        return self.class.new(message, **context) unless ErrorMetadata.known_type?(self.class.name)

        copy = self.class.allocate
        instance_variables.each { |name| copy.instance_variable_set(name, instance_variable_get(name)) }
        Error.instance_method(:initialize).bind_call(copy, message, **context)
        copy
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

    class ScriptOutputLimitExceeded < OutputLimitExceeded; end

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
  end
end
