# frozen_string_literal: true

module Net
  module Connector
    # 传输事件使用从零开始的模式索引；最后一个额外索引表示流式数据。
    Event = Struct.new(:index, :before, :match, :error) do
      # 固定每次读取的字节快照，传输复用缓冲区时不能改写先前分片。
      def initialize(index: nil, before: "".b, match: "".b, error: nil)
        unless before.is_a?(String) && match.is_a?(String)
          raise ArgumentError, "before and match must be Strings"
        end

        before = before.b.freeze unless before.frozen? && before.encoding == Encoding::BINARY
        match = match.b.freeze unless match.frozen? && match.encoding == Encoding::BINARY
        super(index, before, match, error)
        freeze
      end

      # 判断读取是否命中了模式而不是传输错误。
      def matched? = error.nil?

      # 返回事件索引和错误类型摘要。
      def inspect = "#<#{self.class} index=#{index.inspect} error=#{error&.class}>"
    end

  end
end
