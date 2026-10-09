# frozen_string_literal: true

require_relative "settings"

module Net
  module Connector
    module Netdisco
      # 以固定并发上限执行相互隔离的设备任务。
      class Worker
        # 内部预检与实际执行共用规则，不为校验创建工作线程池对象。
        def self.validate_concurrency!(concurrency)
          unless concurrency.is_a?(Integer) && (1..Settings::MAX_CONCURRENCY).cover?(concurrency)
            raise ArgumentError, "concurrency must be an Integer in 1..#{Settings::MAX_CONCURRENCY}"
          end

          concurrency
        end

        # 校验并保存最大设备并发数。
        def initialize(concurrency:)
          @concurrency = Worker.validate_concurrency!(concurrency)
        end

        # 按清单顺序收集结果，并隔离设备及回调异常。
        def run(tasks, outcomes:, on_error:, on_start: nil, on_result: nil)
          queue = Queue.new
          tasks.each { |task| queue << task }
          worker_count = [tasks.size, @concurrency].min
          worker_count.times { queue << nil }
          callback_errors = Queue.new
          finished = Queue.new
          threads = []
          completed = false
          begin
            # 创建线程也属于批次生命周期；后续创建失败时要关闭已有任务。
            worker_count.times do
              threads << Thread.new do
                Thread.current.report_on_exception = false
                while (task = queue.pop)
                  index, device = task
                  result = run_task(device, on_error, on_start, callback_errors) { yield device }
                  outcomes[index] = result
                  Array(on_result).each do |callback|
                    notify(callback, result, host: device.host, errors: callback_errors)
                  end
                end
              ensure
                finished << Thread.current
              end
            end
            # 按完成顺序观察失败，避免后启动线程的中断被前面的慢设备阻塞。
            # 结果仍写回清单槽位，完成通知不会改变公开结果的顺序。
            worker_count.times { finished.pop.value }
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
