# frozen_string_literal: true

require_relative "plan"
require_relative "stages"

module Net
  module Connector
    class Topology
      # 逐接口区分可核实变更、未核实证据和只读平台；计划只包含明确获准的接口范围。
      Audit = Data.define(:plan, :comparisons, :issues, :manual_required) do
        def initialize(plan:, comparisons:, issues:, manual_required:)
          raise ArgumentError, "audit plan must be a topology plan or nil" unless plan.nil? || plan.instance_of?(Plan)
          unless [true, false].include?(manual_required) && comparisons.is_a?(Array) && issues.is_a?(Array)
            raise ArgumentError, "invalid topology audit"
          end
          super(plan: plan, comparisons: copy_rows(comparisons), issues: copy_rows(issues), manual_required: manual_required)
        end

        def complete? = issues.empty?
        def changes = comparisons.count { |entry| !%i[matches unverified].include?(entry[:status]) }
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        private

        def copy_rows(rows)
          rows.map do |row|
            unless row.is_a?(Hash) && row.keys.all?(Symbol) && row.values.all? { |value| value.nil? || value.is_a?(String) || value.is_a?(Symbol) }
              raise ArgumentError, "audit rows must contain scalar metadata"
            end
            row.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
          end.freeze
        end
      end

      # 纯计划构造器不连接设备；协议命令仍由策略及 Stages 生成。
      class AuditBuilder
        def initialize(host:, vendor:, strategy:, neighbors:, descriptions:, formatter:)
          @host, @vendor, @strategy = host, vendor, strategy
          @neighbors, @descriptions, @formatter = neighbors, descriptions, formatter
          @comparisons, @issues, @evidence, @changes = [], [], {}, []
        end

        def call
          groups = @neighbors.group_by { |neighbor| @strategy.interface_key(neighbor.local_interface) }
          groups.each { |interface, peers| inspect_interface(interface, peers) }
          writable = @strategy.supports?(:interface_description_changes)
          plan = build_plan if writable
          Audit.new(plan: plan, comparisons: @comparisons, issues: @issues,
                    manual_required: !writable && @comparisons.any? { |entry| entry[:status] != :matches })
        end

        private

        def inspect_interface(interface, peers)
          peer = peers.first
          current = @descriptions[interface]
          row = { interface: peer.local_interface, neighbor: peer.neighbor_name, port: peer.neighbor_interface,
                  current: current, expected: nil, status: :unverified }
          @comparisons << row
          if peers.size != 1 || peer.neighbor_name.empty? || peer.neighbor_interface.empty?
            return reject_interface(row, :ambiguous_neighbor)
          end
          return reject_interface(row, :interface_missing) unless @descriptions.key?(interface)

          proposed = @formatter.call(peer)
          InterfaceDescription.validate!(proposed)
          local = @strategy.configuration_interface(peer.local_interface)
          InterfaceDescription.validate_interface!(local)
          row.merge!(expected: proposed, status: compare_status(current, proposed))
          @evidence[interface] = [peer.neighbor_name, peer.neighbor_interface, current]
          return if current == proposed

          @changes << Change.new(interface: local, old_description: current, new_description: proposed, neighbor: peer)
        rescue ArgumentError
          reject_interface(row, :unsafe_description)
        end

        def reject_interface(row, code)
          row[:reason] = code
          @issues << { interface: row[:interface], code: code }
          nil
        end

        def compare_status(current, proposed)
          return :matches if current == proposed
          return :missing_description if current.empty?

          :content_mismatch
        end

        def build_plan
          commands = if @changes.empty?
                       []
                     else
                       Stages.build(strategy: @strategy, host: @host, changes: @changes).values.flat_map { |script| script.map(&:text) }
                     end
          Plan.new(host: @host, vendor: @vendor, evidence: @evidence, changes: @changes, commands: commands, scope: :interfaces)
        end
      end
      private_constant :AuditBuilder
    end
  end
end
