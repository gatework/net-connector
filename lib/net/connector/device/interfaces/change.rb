# frozen_string_literal: true

require_relative "neighbor"

module Net
  module Connector
    class Interfaces
      # 变更的描述和接口归本对象所有；邻居值对象可安全共享。
      Change = Data.define(:interface, :old_description, :new_description, :neighbor) do
        # 复制并冻结接口名、新旧描述及对应邻居，固定单接口变更。
        def initialize(interface:, old_description:, new_description:, neighbor:)
          fields = { interface: interface, old_description: old_description, new_description: new_description }
          raise ArgumentError, "description change fields must be Strings" unless fields.values.all?(String)
          raise ArgumentError, "description change requires a Neighbor" unless neighbor.instance_of?(Neighbor)

          super(**fields.transform_values { |value| value.frozen? ? value : value.dup.freeze }, neighbor: neighbor)
        end

        # 返回经校验的更新快照，未更新时沿用当前对象。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
      end
    end
  end
end
