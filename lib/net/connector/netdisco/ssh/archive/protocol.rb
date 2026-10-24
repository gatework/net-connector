# frozen_string_literal: true

require "json"
require_relative "../../tftp/archive"

module Net
  module Connector
    module Netdisco
      module SSH
        module Archive
          # 仅借用事务管道，维护控制帧与二进制正文的分界、缓冲和绝对期限。
          class Protocol
            READ_BYTES = 65_536
            CONTROL_BYTES = 16_384
            PAYLOAD_BYTES = 64 * 1024 * 1024
            private_constant :READ_BYTES, :CONTROL_BYTES, :PAYLOAD_BYTES

            # 每个事务独占自己的协议状态；管道关闭和进程回收仍由客户端负责。
            def initialize(input, output, timeout: 280)
              @input, @output = input, output
              @timeout = timeout
              @buffer = +"".b
            end

            # 发送有界单行控制帧，写入不完整不能当作命令已经交付。
            def send_frame(**values)
              frame = JSON.generate(values) + "\n"
              raise Tftp::Archive::Failure if frame.bytesize > CONTROL_BYTES || @input.write(frame) != frame.bytesize

              @input.flush
            end

            # 开始一个控制阶段；归档元数据取得的期限同时覆盖后续正文及交付确认。
            def expect_phase(phase)
              @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
              read_phase(phase)
            end

            # 按声明长度分片交付二进制正文，随后在同一期限内确认服务器完成交付。
            def read_payload(length)
              unless @phase == "archived" && length.is_a?(Integer) && (1..PAYLOAD_BYTES).cover?(length)
                raise Tftp::Archive::Failure
              end

              remaining = length
              while remaining.positive?
                remaining_time
                @buffer << read_chunk if @buffer.empty?
                chunk = @buffer.slice!(0, [remaining, READ_BYTES, @buffer.bytesize].min)
                remaining -= chunk.bytesize
                yield chunk
              end
              read_phase("delivered")
            end

            private

            # 缓冲中可能同时含有控制帧和正文，只消费当前行并限制控制帧长度。
            def read_phase(phase)
              loop do
                remaining_time
                ending = @buffer.index("\n")
                if ending
                  raise Tftp::Archive::Failure if ending + 1 > CONTROL_BYTES

                  value = JSON.parse(@buffer.slice!(0, ending + 1))
                  unless value.is_a?(Hash) && value["ok"] == true && value["phase"] == phase
                    raise Tftp::Archive::Failure
                  end

                  @phase = phase
                  return value
                end
                raise Tftp::Archive::Failure if @buffer.bytesize >= CONTROL_BYTES

                @buffer << read_chunk
              end
            rescue JSON::ParserError
              raise Tftp::Archive::Failure, cause: nil
            end

            # 每次非阻塞读取使用剩余总预算，片段到达不能重新开始计时。
            def read_chunk
              loop do
                raise Tftp::Archive::Failure unless @output.wait_readable(remaining_time)

                chunk = @output.read_nonblock(READ_BYTES, exception: false)
                next if chunk == :wait_readable
                raise Tftp::Archive::Failure if chunk.nil?

                return chunk
              end
            end

            # 即使数据已经缓冲，也检查绝对期限，避免消费者或确认阶段偷偷延长预算。
            def remaining_time
              remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise Tftp::Archive::Failure unless remaining.positive?

              remaining
            end
          end
        end
      end
    end
  end
end
