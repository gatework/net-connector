# frozen_string_literal: true

require_relative "errors"

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

      # 证据核对只能读取声明的静态响应，不能重新执行动态挑战回调。
      def static_response = (@response if @response.is_a?(String))

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

  end
end
