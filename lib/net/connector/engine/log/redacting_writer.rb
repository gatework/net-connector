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

      private_constant :RedactingWriter
    end
  end
end
