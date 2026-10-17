# frozen_string_literal: true

module Net
  module Connector
    module Device
      # 一个设备任务独占一个连接器；返回值与收尾故障分别保留，不能靠重试恢复写操作。
      module Scope
        # 工厂负责构造，作用域负责关闭；中断仍向调用方传播且不会被第二个关闭故障覆盖。
        def self.call(factory:)
          raise ArgumentError, "factory must respond to call" unless factory.respond_to?(:call)
          raise ArgumentError, "device session requires a block" unless block_given?

          connector = value = failure = nil
          completed = false
          begin
            # 构造器在阻塞等待中仍可取消；非阻塞的返回交接须先登记所有权再交付取消。
            # 工厂尚未返回时的部分资源由工厂清理，成功返回后统一由本作用域关闭。
            Thread.handle_interrupt(Exception => :on_blocking) do
              connector = factory.call
            rescue Exception => error # rubocop:disable Lint/RescueException -- 工厂同步故障先于退出屏蔽范围时交付的取消。
              failure = error
              raise
            end
            value = yield connector
            completed = true
          rescue Exception => error # rubocop:disable Lint/RescueException -- 收尾后保留最先发生的中断，普通故障单独交付业务层。
            failure ||= error
            completed = true
          ensure
            begin
              # 二次异步取消须等待关闭完成，不能在收尾中再次丢失资源所有权。
              Thread.handle_interrupt(Exception => :never) { connector&.close }
            rescue Exception => error # rubocop:disable Lint/RescueException -- 关闭故障不能覆盖原操作故障，包括 Interrupt。
              failure ||= error
            end
            # break 和非局部 return 跳过尾部返回值；收尾故障必须在展开作用域时交付。
            raise failure, cause: failure.cause if failure && (!completed || !failure.is_a?(StandardError))
          end

          [value, failure]
        end
      end
    end
  end
end
