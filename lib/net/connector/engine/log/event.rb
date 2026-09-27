# frozen_string_literal: true

require_relative "../terminal_renderer"
require_relative "messages"

module Net
  module Connector
    class Log
      # 在敏感作用域结束前冻结安全副本；应用 formatter 可直接读取字段。
      class Event
        attr_reader :name, :fields

        def initialize(name, fields, redactor:)
          @name = safe_text(name.is_a?(String) || name.is_a?(Symbol) ? name.to_s : "custom", redactor).freeze
          @fields = fields.each_with_object({}) do |(key, value), result|
            next unless (key.is_a?(Symbol) || key.is_a?(String)) && key.to_s.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
            next unless redactor.call(key.to_s) == key.to_s
            next if key.to_s == "event"

            result[key.to_sym] = safe_value(value, redactor)
          end.freeze
          freeze
        end

        # 与文本呈现共用同一安全记录，调用方不能借 formatter 取得原始秘密。
        def to_h = { event: name, **fields }.freeze

        def to_s
          details = to_h.reject { |key, _| key == :host }.map { |key, value| "#{key}=#{token(value)}" }.join(" ")
          "[host=#{token(fields[:host])}] #{Messages.format(name, fields)} | #{details}"
        end

        # Ruby Logger 的默认 formatter 对非 String 消息调用 inspect。
        alias inspect to_s

        private

        def safe_value(value, redactor)
          case value
          when String, Symbol
            safe_text(value.to_s, redactor).freeze
          when Float
            value.finite? && redactor.call(value.to_s) == value.to_s ? value : "[REDACTED]"
          when Integer, TrueClass, FalseClass, NilClass
            redactor.call(value.to_s) == value.to_s ? value : "[REDACTED]"
          else
            # 不调用任意对象的 inspect/to_s，避免展开异常、配置对象或容器中的秘密。
            "[REDACTED]"
          end
        end

        def safe_text(text, redactor)
          rendered = TerminalRenderer.render(redactor.call(text))
          redactor.call(rendered).force_encoding(Encoding::UTF_8).scrub.gsub(/[[:cntrl:]]+/, " ").strip
        end

        def token(value)
          return "nil" if value.nil?

          text = value.to_s
          text.match?(/\A[A-Za-z0-9_.:\/-]+\z/) ? text : text.inspect
        end
      end
    end
  end
end
