# frozen_string_literal: true

module Net
  module Connector
    # 后台观察线程属于调用作用域；停止、等待和异常交付不能盖掉前台原故障。
    module BackgroundTask
      # task 自行等待停止信号，stop 只负责唤醒；正常前台也必须观察后台失败。
      def self.run(task:, stop:)
        unless task.respond_to?(:call) && stop.respond_to?(:call) && block_given?
          raise ArgumentError, "background task requires task, stop and a foreground block"
        end

        thread = value = failure = nil
        completion = Queue.new
        begin
          # 创建与登记之间不交付异步中断；子线程恢复即时交付，捕获后同步传回所有者。
          Thread.handle_interrupt(Exception => :never) do
            thread = Thread.new { observe(task, completion) }
          end
          value = yield
        rescue Exception => error # rubocop:disable Lint/RescueException -- 收尾后向所有者重新抛出原故障，包括中断。
          failure = error
        ensure
          begin
            # 二次中断不能跳过 join；恢复交付时也保留已经发生的前台故障。
            Thread.handle_interrupt(Exception => :never) do
              cleanup_error = finish(thread, stop) if thread
              failure ||= cleanup_error
            end
          rescue Exception => error # rubocop:disable Lint/RescueException -- 保留前台故障，观察延迟到达的取消。
            failure ||= error
          end
          # break 和非局部 return 也会展开作用域；异常交付必须在 ensure 内，不能绕过。
          failure ||= completion.pop unless completion.empty?
          raise failure, cause: failure.cause if failure
        end
        value
      end

      def self.observe(task, completion)
        failure = nil
        Thread.handle_interrupt(Exception => :immediate) { task.call }
      rescue Exception => error # rubocop:disable Lint/RescueException -- 不让 global abort_on_exception 将子线程故障传播到无关主线程。
        failure = error
      ensure
        completion << failure
      end
      private_class_method :observe

      def self.finish(thread, stop)
        failure = nil
        begin
          stop.call
        rescue Exception => error # rubocop:disable Lint/RescueException -- 唤醒失败时仍必须终止并回收自有线程。
          failure = error
          thread.kill
        ensure
          begin
            thread.join
          rescue Exception => error # rubocop:disable Lint/RescueException -- 等待失败也不能覆盖先前故障。
            failure ||= error
          end
        end
        failure
      end
      private_class_method :finish
    end
  end
end
