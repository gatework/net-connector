# frozen_string_literal: true

require_relative "../execution_pool"

module Net
  module Connector
    module Netdisco
      # 以固定并发上限执行相互隔离的设备任务。
      class Worker
        # 内部预检与实际执行共用规则，不为校验创建工作线程池对象。
        def self.validate_concurrency!(concurrency)
          ExecutionPool.validate_concurrency!(concurrency)
        end

        # 校验并保存最大设备并发数。
        def initialize(concurrency:)
          @concurrency = Worker.validate_concurrency!(concurrency)
        end

        # 按清单顺序收集结果，并隔离设备及回调异常。
        def run(tasks, outcomes:, on_error:, on_start: nil, on_result: nil)
          callback_errors = Queue.new
          ExecutionPool.new(concurrency: @concurrency).map(tasks) do |index, device|
            result = run_task(device, on_error, on_start, callback_errors) { yield device }
            outcomes[index] = result
            Array(on_result).each do |callback|
              notify(callback, result, host: device.host, errors: callback_errors)
            end
          end
          Array.new(callback_errors.size) { callback_errors.pop }.freeze
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
