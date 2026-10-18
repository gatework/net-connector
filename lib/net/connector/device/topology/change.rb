# frozen_string_literal: true

require_relative "neighbor"

module Net
  module Connector
    class Topology
      # 变更的描述和接口归本对象所有；邻居值对象可安全共享。
      Change = Data.define(:interface, :old_description, :new_description, :neighbor) do
        def initialize(interface:, old_description:, new_description:, neighbor:)
          fields = { interface: interface, old_description: old_description, new_description: new_description }
          raise ArgumentError, "description change fields must be Strings" unless fields.values.all?(String)
          raise ArgumentError, "description change requires a Neighbor" unless neighbor.instance_of?(Neighbor)

          super(**fields.transform_values { |value| value.frozen? ? value : value.dup.freeze }, neighbor: neighbor)
        end

        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
      end
    end
  end
end
