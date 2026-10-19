# frozen_string_literal: true

module Net
  module Connector
    # 在厂商清理前保留原始字节，供诊断和日志使用。
    class Response
      # 只读提供原始字节、处理后输出及结束提示符。
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
