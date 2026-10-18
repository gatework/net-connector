# frozen_string_literal: true

module Net
  module Connector
    class Topology
      # 邻居身份拥有独立字符串，格式化回调不能改写发现证据。
      Neighbor = Data.define(:local_interface, :neighbor_name, :neighbor_interface, :chassis_id, :protocol) do
        def initialize(local_interface:, neighbor_name:, neighbor_interface:, chassis_id:, protocol:)
          fields = { local_interface: local_interface, neighbor_name: neighbor_name,
                     neighbor_interface: neighbor_interface, chassis_id: chassis_id }
          raise ArgumentError, "neighbor fields must be Strings" unless fields.values.all?(String)
          raise ArgumentError, "neighbor protocol must be a Symbol" unless protocol.is_a?(Symbol)

          super(**fields.transform_values { |value| value.frozen? ? value : value.dup.freeze }, protocol: protocol)
        end

        # Ruby 3.2 的 Data#with 不调用初始化，更新也必须重新建立快照。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
      end
    end
  end
end
