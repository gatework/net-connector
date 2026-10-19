# frozen_string_literal: true

require "shellwords"
require_relative "../../engine/errors"

module Net
  module Connector
    class Interfaces
      # 配置字段的引号解码是纯文本边界，不执行 shell，也不把原文写入错误。
      module QuotedText
        # 按设备配置的引号规则还原描述文本，格式不完整时返回受控解析错误。
        def self.decode(value, host:, split_unquoted: false)
          value = value.strip
          return value unless split_unquoted || value.start_with?('"')

          Shellwords.split(value).join(" ")
        rescue ArgumentError
          raise ParsingError.new("interface description is not a complete single-line value",
                                 code: :unrecognized_output, host: host, phase: :parse), cause: nil
        end
      end
    end
  end
end
