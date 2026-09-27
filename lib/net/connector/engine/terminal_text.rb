# frozen_string_literal: true

require_relative "terminal_renderer"
require_relative "errors"

module Net
  module Connector
    # 设备/文件提供的是字节，不受 Ruby 源文件编码控制。解析边界只接受 UTF-8，
    # 不猜测编码、不改写原文，也不让终端编辑把非法字节抹掉后变成可信证据。
    module TerminalText
      def self.utf8(bytes, host: nil)
        raise ArgumentError, "text must be a String" unless bytes.is_a?(String)

        text = bytes.b.force_encoding(Encoding::UTF_8)
        invalid_encoding!(host) unless text.valid_encoding?
        text
      end

      def self.render(bytes, host: nil)
        TerminalRenderer.render(utf8(bytes, host: host), strict_utf8: true).force_encoding(Encoding::UTF_8)
      rescue Encoding::InvalidByteSequenceError
        invalid_encoding!(host)
      end

      def self.invalid_encoding!(host)
        raise ParsingError.new("device output is not valid UTF-8", code: :invalid_output_encoding,
                               host: host, phase: :parse), cause: nil
      end

      private_class_method :invalid_encoding!
    end
  end
end
