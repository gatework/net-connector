# frozen_string_literal: true

require_relative "../inventory"

module Net
  module Connector
    module Netdisco
      module Inventory
        # 每次 devices 调用独占一个预算，认证、分页和兼容查询不得重置已用资源或期限。
        # @api private
        class Budget
          # 为一次完整清单读取建立总截止时间及累计字节、设备计数。
          def initialize(options, clock:)
            @options = options
            @clock = clock
            @deadline = @clock.call + options.fetch(:inventory_timeout)
            @bytes = 0
            @devices = 0
          end

          # 返回本次读取剩余秒数，预算耗尽时立即抛出清单超时。
          def remaining
            seconds = @deadline - @clock.call
            raise Inventory::Timeout, cause: nil if seconds <= 0

            seconds
          end

          # 在追加正文前计数；不能靠 Content-Length 或 JSON 解析后的大小限制内存。
          def consume_bytes(size, response_bytes:)
            remaining
            validate_limit!(:max_response_bytes, response_bytes + size)
            validate_limit!(:max_inventory_bytes, @bytes + size)
            @bytes += size
          end

          # 去重前的记录同样占用清单内存；兼容查询也使用这个累计计数。
          def consume_devices(size)
            remaining
            validate_limit!(:max_devices, @devices + size)
            @devices += size
          end

          private

          # 检查累计资源量是否超过指定上限，超限时返回稳定错误码。
          def validate_limit!(name, value)
            return if value <= @options.fetch(name)

            raise Inventory::Error.new("Netdisco inventory exceeded #{name}", code: name), cause: nil
          end
        end
      end
    end
  end
end
