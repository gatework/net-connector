# frozen_string_literal: true

require_relative "parallel/pool"

module Net
  module Connector
    # 设备批次启动前准备本进程文件额度，不修改 shell 配置或系统全局限制。
    module Resources
      # 每台预留 SSH 管道、伪终端、日志及文件锁，基础额度覆盖清单和主连接开销。
      DESCRIPTORS_PER_DEVICE = 16
      BASE_DESCRIPTORS = 128
      LOCK = Mutex.new
      private_constant :DESCRIPTORS_PER_DEVICE, :BASE_DESCRIPTORS, :LOCK

      # 按实际活跃设备数预检；空批次不调整限制，非法输入与资源不足分别诊断。
      def self.prepare!(parallel:)
        return if parallel.is_a?(Integer) && parallel.zero?

        Parallel::Pool.validate_parallel!(parallel)
        required = BASE_DESCRIPTORS + (DESCRIPTORS_PER_DEVICE * parallel)
        reserve!(required, parallel)
      end

      # 只在进程硬上限内提高软上限；失败时整批尚未开始连接设备。
      def self.reserve!(required, parallel)
        LOCK.synchronize do
          soft, hard = Process.getrlimit(:NOFILE)
          return if soft >= required

          raise ArgumentError if hard < required

          Process.setrlimit(:NOFILE, required, hard)
        end
      rescue SystemCallError, ArgumentError, NotImplementedError
        raise ArgumentError, "Insufficient local file descriptor limit: #{parallel} concurrent devices require at least #{required} file descriptors; raise the terminal ulimit -n or lower --parallel. Stopped without connecting to devices.", cause: nil
      end
      private_class_method :reserve!
    end
  end
end
