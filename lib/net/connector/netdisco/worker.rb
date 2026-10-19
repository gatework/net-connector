# frozen_string_literal: true

require_relative "../parallel/pool"

module Net
  module Connector
    module Netdisco
      # 以固定并发上限执行相互隔离的设备任务。
      class Worker
        # 读取本次任务启动记录和通知故障，用于取消后的结果汇总。
        attr_reader :started_tasks, :callback_errors
        # 内部预检与实际执行共用规则，不为校验创建工作线程池对象。
        def self.validate_parallel!(parallel)
          Parallel::Pool.validate_parallel!(parallel)
        end

        # 校验并保存最大设备并发数。
        def initialize(parallel:)
          @parallel = Worker.validate_parallel!(parallel)
        end

        # 按清单顺序收集结果，并隔离设备及回调异常。
        def run(tasks, outcomes:, on_error:, on_start: nil, on_result: nil)
          callback_errors = Queue.new
          @started_tasks = {}
          @callback_errors = nil
          callbacks = (on_result.is_a?(Array) ? on_result : [on_result]).compact
          Parallel::Pool.new(parallel: @parallel).map(tasks) do |index, device|
            @started_tasks[index] = Time.now.utc.freeze
            # 阻塞设备 I/O 仍可取消；非阻塞的结果返回必须先发布，避免已保存产物丢失回执。
            Thread.handle_interrupt(Exception => :on_blocking) do
              result = run_task(device, on_error, on_start, callback_errors) { yield device }
              outcomes[index] = result
            end
            callbacks.each do |callback|
              notify(callback, outcomes[index], host: device.host, errors: callback_errors)
            end
          end
          Thread.handle_interrupt(Exception => :never) do
            @callback_errors = Array.new(callback_errors.size) { callback_errors.pop }.freeze
          end
        rescue Exception => error # rubocop:disable Lint/RescueException -- 登记主故障，收尾取消不能覆盖它。
          failure = error
          raise
        ensure
          begin
            # Pool 已回收线程；二次取消不能打断启动记录与通知故障的交付。
            Thread.handle_interrupt(Exception => :never) do
              @started_tasks&.freeze
              @callback_errors ||= Array.new(callback_errors.size) { callback_errors.pop }.freeze if callback_errors
            end
          rescue Exception => error # rubocop:disable Lint/RescueException -- 保留已登记的主故障或首个收尾取消。
            error = failure || error
            raise error, cause: error.cause
          end
        end

        private

        # 普通设备故障转换为结果，中断仍交给批次统一停止其余线程。
        def run_task(device, on_error, on_start, callback_errors)
          started_at = Time.now.utc
          started = monotonic
          notify(on_start, device, host: device.host, errors: callback_errors) unless on_start.nil?
          result = begin
                     yield
                   rescue StandardError => error
                     on_error.call(device, error)
                   end
          result.with(started_at: started_at, finished_at: Time.now.utc, duration_ms: ((monotonic - started) * 1000).round)
        end

        # 读取单调时钟秒数，避免系统校时影响期限与耗时计算。
        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # 回调故障不覆盖设备结果，也不把异常消息中的凭据写入报告。
        def notify(callback, value, host:, errors:)
          callback.call(value)
        rescue StandardError => error
          errors << { host: host, error_type: error.class.name }.freeze
        end
      end
    end
  end
end
