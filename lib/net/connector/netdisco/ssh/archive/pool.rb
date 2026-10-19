# frozen_string_literal: true

require_relative "client"
require_relative "../../../parallel/pool"

module Net
  module Connector
    module Netdisco
      module SSH
        # SSH 归档的客户端、连接调度与服务器事务实现。
        module Archive
          # 将批次并发分摊到多个 SSH 主连接，避免单连接槽位串行化设备任务。
          class Pool
            # 每条连接最多四个会话；所有连接合计不超过批次授权的设备并发。
            def initialize(directory:, root:, password:, parallel:)
              Parallel::Pool.validate_parallel!(parallel)
              @archives = []
              @available = SizedQueue.new(parallel)
              remaining = parallel
              while remaining.positive?
                archive = Client.new(directory: directory, root: root, password: password)
                @archives << archive
                count = [remaining, Client::SESSION_LIMIT].min
                count.times { @available << archive }
                remaining -= count
              end
            end

            # 所有主连接及服务器目录均预检通过后才允许设备任务开始。
            def prepare
              Parallel::Pool.new(parallel: [@archives.size, Client::SESSION_LIMIT].min).map(@archives, &:prepare)
            rescue Exception # rubocop:disable Lint/RescueException -- 预检取消或失败时先回收全部主连接，保留首错。
              close
              raise
            end

            # 文件名策略与单连接归档一致；服务器目标锁仍跨连接互斥。
            def upload_filename(device) = @archives.first.upload_filename(device)

            # 借用一个有空闲会话的主连接，事务结束或中断后归还槽位。
            def upload_and_archive(device, started_at:, &)
              archive = @available.pop
              archive.upload_and_archive(device, started_at: started_at, &)
            ensure
              @available << archive if archive
            end

            # 尝试关闭全部所属连接，保留最先发生的故障或原始中断。
            def close
              primary = $!
              failure = nil
              Thread.handle_interrupt(Exception => :never) do
                @archives.each do |archive|
                  begin
                    archive.close
                  rescue Exception => error # rubocop:disable Lint/RescueException -- 一个连接关闭失败仍须回收其余连接。
                    failure ||= error
                  end
                end
                raise failure if failure && !primary
              end
            rescue Exception => error # rubocop:disable Lint/RescueException -- 恢复中断交付后仍保留原操作或首个关闭故障。
              error = primary || failure || error
              raise error, cause: error.cause
            end
          end
        end
      end
    end
  end
end
