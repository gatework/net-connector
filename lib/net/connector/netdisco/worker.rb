# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      # 以固定并发上限执行相互隔离的设备任务。
      class Worker
        # 校验并保存最大设备并发数。
        def initialize(concurrency:)
          unless concurrency.is_a?(Integer) && (1..Settings::MAX_CONCURRENCY).cover?(concurrency)
            raise ArgumentError, "concurrency must be an Integer in 1..#{Settings::MAX_CONCURRENCY}"
          end

          @concurrency = concurrency
        end

        # 按清单顺序收集结果，并隔离设备及回调异常。
        def run(tasks, outcomes:, on_error:, on_start: nil, on_result: nil)
          queue = Queue.new
          tasks.each { |task| queue << task }
          worker_count = [tasks.size, @concurrency].min
          worker_count.times { queue << nil }
          callback_errors = Queue.new
          threads = Array.new(worker_count) do
            Thread.new do
              Thread.current.report_on_exception = false
              while (task = queue.pop)
                index, device = task
                started_at = Time.now.utc
                begin
                  on_start&.call(device)
                rescue StandardError => error
                  callback_errors << { host: device.host, error_type: error.class.name }.freeze
                end
                result = begin
                           yield device
                         rescue StandardError => error
                           on_error.call(device, error)
                         end
                result = result.with(started_at: started_at, finished_at: Time.now.utc)
                outcomes[index] = result
                Array(on_result).each do |callback|
                  begin
                    callback.call(result)
                  rescue StandardError => error
                    callback_errors << { host: device.host, error_type: error.class.name }.freeze
                  end
                end
              end
            end
          end
          completed = false
          begin
            threads.each(&:value)
            completed = true
          ensure
            # 中断或某个 worker 抛出非 StandardError 时，不让其他设备任务
            # 在调用方已经退出后继续运行；Thread#kill 会执行任务自身的 ensure。
            unless completed
              threads.each(&:kill)
              threads.each do |thread|
                begin
                  thread.join
                rescue Exception # rubocop:disable Lint/RescueException -- Preserve the original interruption after all workers stop.
                  nil
                end
              end
            end
          end
          Array.new(callback_errors.size) { callback_errors.pop }.freeze
        end
      end
    end
  end
end
