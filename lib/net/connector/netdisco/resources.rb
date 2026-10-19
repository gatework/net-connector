# frozen_string_literal: true

require_relative "../parallel/pool"

module Net
  module Connector
    module Netdisco
      # 设备批次启动前准备本进程文件额度，不修改 shell 配置或系统全局限制。
      module Resources
        # 每台预留 SSH 管道、伪终端、日志及文件锁，基础额度覆盖清单和主连接开销。
        DESCRIPTORS_PER_DEVICE = 16
        BASE_DESCRIPTORS = 128
        LOCK = Mutex.new
        private_constant :DESCRIPTORS_PER_DEVICE, :BASE_DESCRIPTORS, :LOCK

        # 在硬上限以内提高软上限；无法满足时先拒绝整批，避免逐设备资源耗尽。
        def self.prepare!(parallel:)
          return if parallel.zero?

          Parallel::Pool.validate_parallel!(parallel)
          required = BASE_DESCRIPTORS + (DESCRIPTORS_PER_DEVICE * parallel)
          LOCK.synchronize do
            soft, hard = Process.getrlimit(:NOFILE)
            return if soft >= required

            raise ArgumentError if hard < required

            Process.setrlimit(:NOFILE, required, hard)
          end
        rescue SystemCallError, ArgumentError, NotImplementedError
          raise ArgumentError, "本机文件描述符额度不足：#{parallel} 并发至少预留 #{required} 个文件描述符；请提高终端 ulimit -n 或降低 --parallel。已停止，未连接设备。", cause: nil
        end
      end
    end
  end
end
