# frozen_string_literal: true

module Net
  module Connector
    class Topology
      # 邻居身份拥有独立字符串，格式化回调不能改写发现证据。
      Neighbor = Data.define(:local_interface, :neighbor_name, :neighbor_interface, :chassis_id, :protocol) do
        # 复制并冻结本地端口、邻居名称、远端端口及发现协议。
        def initialize(local_interface:, neighbor_name:, neighbor_interface:, chassis_id:, protocol:)
          fields = { local_interface: local_interface, neighbor_name: neighbor_name,
                     neighbor_interface: neighbor_interface, chassis_id: chassis_id }
          raise ArgumentError, "neighbor fields must be Strings" unless fields.values.all?(String)
          raise ArgumentError, "neighbor protocol must be a Symbol" unless protocol.is_a?(Symbol)

          super(**fields.transform_values { |value| value.frozen? ? value : value.dup.freeze }, protocol: protocol)
        end

        # 原始发现数据保留占位符；规划与下发重验共用身份校验，不能把未知名称写入描述。
        # MAC 是合法的 LLDP Port ID，不凭地址形状猜测设备角色，也不拿 chassis ID 补造名称。
        def identity_issue
          return :unknown_neighbor_name if unknown_identity?(neighbor_name)
          return :unknown_neighbor_interface if unknown_identity?(neighbor_interface)

          nil
        end

        # Ruby 3.2 的 Data#with 不调用初始化，更新也必须重新建立快照。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        private

        # 厂商占位符不构成可确认身份；忽略边界空白和大小写，不改变原始证据。
        def unknown_identity?(value)
          value.strip.match?(/\A(?:-+|n\/?a|unknown|none|null|not\s+(?:available|advertised))?\z/i)
        end
      end
    end
  end
end
