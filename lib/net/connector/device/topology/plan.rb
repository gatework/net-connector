# frozen_string_literal: true

require_relative "change"

module Net
  module Connector
    class Topology
      # 审批树在领域边界固定；单设备与批量操作共享同一不可变计划。
      Plan = Data.define(:host, :vendor, :evidence, :changes, :commands, :scope) do
        def initialize(host:, vendor:, evidence:, changes:, commands:, scope: :device)
          unless host.is_a?(String) && vendor.is_a?(Symbol) && evidence.is_a?(Hash) &&
                 changes.is_a?(Array) && changes.all? { |change| change.instance_of?(Change) } &&
                 commands.is_a?(Array) && commands.all?(String) && %i[device interfaces].include?(scope)
            raise ArgumentError, "description plan contains invalid fields"
          end

          super(host: host.frozen? ? host : host.dup.freeze, vendor: vendor,
                evidence: copy_evidence(evidence), changes: changes.dup.freeze,
                commands: commands.map { |command| command.frozen? ? command : command.dup.freeze }.freeze, scope: scope)
        end

        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        private

        def copy_evidence(evidence)
          evidence.to_h do |interface, fields|
            unless interface.is_a?(String) && fields.is_a?(Array) && fields.size == 3 && fields.all?(String)
              raise ArgumentError, "description plan contains invalid evidence"
            end

            [interface.frozen? ? interface : interface.dup.freeze,
             fields.map { |field| field.frozen? ? field : field.dup.freeze }.freeze]
          end.freeze
        end
      end
    end
  end
end
