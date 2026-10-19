# frozen_string_literal: true

module Net
  module Connector
    class Log
      # 每个目标独占 expect-pty 的过滤流；此层只适配 IO，不实现匹配算法。
      class RedactingWriter
        # 绑定日志目标及当前脱敏器，创建该目标独占的流式过滤状态。
        def initialize(target, redactor)
          @target = target
          @redactor = redactor
          @filter = redactor.stream
        end

        # 同步最新秘密词表，过滤分片后写入目标并返回原始输入字节数。
        def write(bytes)
          @filter.patterns = @redactor.patterns
          @target.write(@filter.append(bytes.b))
          bytes.bytesize
        end

        # 刷新底层日志目标，不提前结束流式秘密匹配。
        def flush = @target.flush

        # 输出过滤器中可公开的剩余字节，再刷新日志目标。
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
