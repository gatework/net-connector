# frozen_string_literal: true

module Net
  module Connector
    class Log
      # 每个目标独占 expect-pty 的过滤流；此层只适配 IO，不实现匹配算法。
      class RedactingWriter
        def initialize(target, redactor)
          @target = target
          @redactor = redactor
          @filter = redactor.stream
        end

        def write(bytes)
          @filter.patterns = @redactor.patterns
          @target.write(@filter.append(bytes.b))
          bytes.bytesize
        end

        def flush = @target.flush

        def finish
          @filter.patterns = @redactor.patterns
          # 配置正文由 Session 的敏感范围隔离；保留完整词匹配的收尾契约。
          @target.write(@filter.finish(partial: false))
          flush
        end
      end

      # 已渲染、已脱敏的字节按行变成事件，半行在上下文切换前收尾。
      class Transcript
        def initialize(&on_line)
          @on_line = on_line
          @buffer = +"".b
        end

        def write(bytes)
          @buffer << bytes
          while (ending = @buffer.index("\n"))
            @on_line.call(@buffer.slice!(0, ending + 1).chomp)
          end
          bytes.bytesize
        end

        def flush; end

        def finish
          @on_line.call(@buffer) unless @buffer.empty?
          @buffer = +"".b
        end
      end

      private_constant :RedactingWriter, :Transcript
    end
  end
end
