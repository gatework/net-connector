# frozen_string_literal: true

module Net
  module Connector
    module Concurrency
      # 仅管理有限并发和线程所有权；业务层负责将普通任务故障转换为领域结果。
      class Pool
        DEFAULT_CONCURRENCY = 4
        MAX_CONCURRENCY = 50

        def self.validate_concurrency!(concurrency)
          unless concurrency.is_a?(Integer) && (1..MAX_CONCURRENCY).cover?(concurrency)
            raise ArgumentError, "concurrency must be an Integer in 1..#{MAX_CONCURRENCY}"
          end

          concurrency
        end

        # 环境只提供默认并发数；显式构造参数优先，非法值不创建线程。
        def self.environment_concurrency(env: ENV)
          value = env.fetch("NC_CONCURRENCY", DEFAULT_CONCURRENCY.to_s)
          unless value.is_a?(String) && value.match?(/\A[0-9]+\z/)
            raise ArgumentError, "NC_CONCURRENCY must be a positive integer"
          end

          validate_concurrency!(Integer(value, 10))
        end

        def initialize(concurrency: self.class.environment_concurrency)
          @concurrency = self.class.validate_concurrency!(concurrency)
        end

        # 保序返回块的值；任何未处理异常均在调用线程抛出，停止并回收本次所有线程。
        # 只复制任务数组，任务内容仍由业务层在下发前校验和固定，不自动重放块。
        def map(items)
          raise ArgumentError, "items must be an Array" unless items.is_a?(Array)
          raise ArgumentError, "map requires a block" unless block_given?

          items = items.dup
          queue = Queue.new
          items.each_with_index { |item, index| queue << [index, item] }
          count = [items.size, @concurrency].min
          count.times { queue << nil }
          gate = Queue.new
          finished = Queue.new
          results = Array.new(items.size)
          threads = []
          completed = false
          primary_failure = nil
          begin
            count.times do
              # 仅延迟线程创建到登记的异步中断，避免尚未登记的工作线程失去所有者。
              Thread.handle_interrupt(Exception => :never) do
                threads << Thread.new do
                  failure = nil
                  exhausted = false
                  begin
                    # 全部线程成功建立后才允许设备操作，创建失败不能留下已发送的变更。
                    Thread.handle_interrupt(Exception => :immediate) do
                      gate.pop
                      while (task = queue.pop)
                        index, item = task
                        results[index] = yield item
                      end
                      exhausted = true
                    end
                  rescue Exception => error # rubocop:disable Lint/RescueException -- 将中断同步交给调用线程，避免全局 abort_on_exception 波及其他线程。
                    failure = error
                  ensure
                    # Thread.exit/kill 不经过 rescue；不能把尚未完成的任务伪装成合法 nil 结果。
                    failure ||= RuntimeError.new("execution worker stopped before completing its tasks") unless exhausted
                    finished << [Thread.current, failure]
                  end
                end
              end
            end
            count.times { gate << true }
            count.times do
              thread, failure = finished.pop
              thread.join
              raise failure, cause: failure.cause if failure
            end
            completed = true
          rescue Exception => error # rubocop:disable Lint/RescueException -- 记录取消或原任务故障，收尾中再次取消不能覆盖它。
            primary_failure = error
            raise
          ensure
            stop_threads(threads, primary_failure) unless completed
          end
          results
        end

        private

        # kill 运行任务自身的 ensure；次级关闭故障不能盖掉已观察到的原始异常。
        def stop_threads(threads, primary_failure)
          # 仅回收期间延迟异步取消；交付二次中断之前必须 kill 并 join 全部拥有线程。
          Thread.handle_interrupt(Exception => :never) do
            threads.each(&:kill)
            threads.each do |thread|
              begin
                thread.join
              rescue Exception # rubocop:disable Lint/RescueException -- 等待全部拥有线程收尾，保留调用方原始故障或中断。
                nil
              end
            end
          end
        rescue Exception => error # rubocop:disable Lint/RescueException -- 恢复交付时保留原故障，二次取消不改变批次失败原因。
          # 二次取消可能已以原故障为 cause；不能反向关联形成异常原因环。
          error = primary_failure || error
          raise error, cause: error.cause
        end
      end
    end
  end
end
