# frozen_string_literal: true

module Net
  module Connector
    class Log
      # 已渲染、已脱敏的字节按行变成事件，半行在上下文切换前收尾。
      class Transcript
        def initialize(&on_line)
          @on_line = on_line
          @buffer = +"".b
        end

        def write(bytes)
          @buffer << bytes
          while (ending = @buffer.index("\n"))
            @on_line.call(@buffer.slice!(0, ending + 1).chomp("\n"))
          end
          bytes.bytesize
        end

        def flush; end

        def finish
          @on_line.call(@buffer) unless @buffer.empty?
          @buffer = +"".b
        end
      end

      private_constant :Transcript
    end
  end
end
