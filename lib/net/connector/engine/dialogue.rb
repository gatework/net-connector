# frozen_string_literal: true

require_relative "errors"
require_relative "terminal_renderer"

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

      # 只截取命中错误模式的当前行，避免把整段设备配置写进诊断信息。
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
  end
end
