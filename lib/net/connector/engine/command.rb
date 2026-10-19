# frozen_string_literal: true

require_relative "errors"
require_relative "interaction"
require "expect/pty"

module Net
  module Connector
    # 一条设备命令行，可附带独立截止时间和交互规则。
    class Command
      # 只读提供命令文本、超时、交互、提示符及脚本来源信息。
      attr_reader :text, :timeout, :interactions, :prompt, :source, :line

      # 在任何输入输出前校验命令、提示、交互和敏感标记，并冻结命令。
      def initialize(text, timeout: nil, interactions: [], prompt: nil, sensitive: false, output_sensitive: false,
                     source: nil, line: nil)
        unless text.is_a?(String) && !text.strip.empty? && !text.match?(/[\r\n\x00]/)
          raise ScriptError.new("a command must contain exactly one nonempty CLI line", phase: :parse,
                                source: source, line: line)
        end
        unless interactions.is_a?(Array) && interactions.all?(Interaction)
          raise ArgumentError, "interactions must be an Array of Interaction objects"
        end
        valid_prompt = prompt.nil? || (prompt.is_a?(Regexp) && !prompt.match?(""))
        unless valid_prompt
          raise ArgumentError, "prompt must be a nonempty Regexp or nil"
        end
        raise ArgumentError, "sensitive must be true or false" unless [true, false].include?(sensitive)
        raise ArgumentError, "output_sensitive must be true or false" unless [true, false].include?(output_sensitive)

        @text = text.dup.freeze
        @timeout = Expect.duration(timeout)
        @interactions = interactions.dup.freeze
        @prompt = prompt
        @sensitive = sensitive
        @output_sensitive = output_sensitive
        @source = source&.dup&.freeze
        @line = line
        freeze
      end

      # 判断命令文本是否需要脱敏。
      def sensitive? = @sensitive

      # 响应正文可能包含尚未登记的秘密，与命令文本是否敏感无关。
      def output_sensitive? = @output_sensitive

      # 复制命令元数据，只替换命令文本。
      def with_text(text)
        self.class.new(text, timeout: timeout, interactions: interactions, prompt: prompt,
                       sensitive: sensitive?, output_sensitive: output_sensitive?, source: source, line: line)
      end

      # 配置采集保留调用方的全部命令元数据，只收紧输出的诊断边界。
      def with_output_sensitive
        self.class.new(text, timeout: timeout, interactions: interactions, prompt: prompt,
                       sensitive: sensitive?, output_sensitive: true, source: source, line: line)
      end

      # 返回命令来源摘要，不展开命令内容。
      def inspect = "#<#{self.class} source=#{source.inspect} line=#{line.inspect}>"
    end

  end
end
