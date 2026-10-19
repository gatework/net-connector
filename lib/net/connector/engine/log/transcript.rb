# frozen_string_literal: true

module Net
  module Connector
    class Log
      # 已渲染、已脱敏的字节按行变成事件，半行在上下文切换前收尾。
      class Transcript
        # 保存逐行事件回调，并创建当前未完成行的字节缓冲。
        def initialize(&on_line)
          @on_line = on_line
          @buffer = +"".b
        end

        # 积累字节并逐行交付回调，保留尾部半行供后续分片补全。
        def write(bytes)
          @buffer << bytes
          while (ending = @buffer.index("\n"))
            @on_line.call(@buffer.slice!(0, ending + 1).chomp("\n"))
          end
          bytes.bytesize
        end

        # 保留尚未完成的行，不因刷新请求提前生成事件。
        def flush; end

        # 交付最后一个非空半行，并重置缓冲。
        def finish
          @on_line.call(@buffer) unless @buffer.empty?
          @buffer = +"".b
        end
      end

      private_constant :Transcript
    end
  end
end
