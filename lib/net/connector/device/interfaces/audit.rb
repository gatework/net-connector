# frozen_string_literal: true

require_relative "plan"
require_relative "stages"

module Net
  module Connector
    class Interfaces
      # 逐接口区分可核实变更、未核实证据和只读平台；计划只包含明确获准的接口范围。
      Audit = Data.define(:plan, :comparisons, :issues, :manual_required) do
        # 校验并复制审计计划、接口比较与问题列表，避免调用方修改证据。
        def initialize(plan:, comparisons:, issues:, manual_required:)
          raise ArgumentError, "audit plan must be a topology plan or nil" unless plan.nil? || plan.instance_of?(Plan)
          unless [true, false].include?(manual_required) && comparisons.is_a?(Array) && issues.is_a?(Array)
            raise ArgumentError, "invalid topology audit"
          end
          super(plan: plan, comparisons: copy_rows(comparisons), issues: copy_rows(issues), manual_required: manual_required)
        end

        # 判断审计是否没有尚未解决的证据问题。
        def complete? = issues.empty?
        # 统计需要处理的接口比较项，不将未核实接口计为可执行变更。
        def changes = comparisons.count { |entry| !%i[matches unverified].include?(entry[:status]) }
        # 返回经校验的更新快照，未更新时沿用当前对象。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        private

        # 只复制标量审计元数据，冻结行和容器以保护审批证据。
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
        # 保存离线审计输入，并建立独立的比较、问题、证据和变更容器。
        def initialize(host:, vendor:, strategy:, neighbors:, descriptions:, formatter:, description_matcher: nil)
          @host, @vendor, @strategy = host, vendor, strategy
          @neighbors, @descriptions, @formatter = neighbors, descriptions, formatter
          @description_matcher = description_matcher || ->(current, proposed, _peer) { Description.equivalent?(current, proposed) }
          @comparisons, @issues, @evidence, @changes = [], [], {}, []
        end

        # 按本地接口分组审计邻居和描述，仅为可写平台生成已核实计划。
        def call
          groups = @neighbors.group_by { |neighbor| @strategy.interface_key(neighbor.local_interface) }
          groups.each { |interface, peers| inspect_interface(interface, peers) }
          writable = @strategy.supports?(:interface_description_changes)
          plan = build_plan if writable
          Audit.new(plan: plan, comparisons: @comparisons, issues: @issues,
                    manual_required: !writable && @comparisons.any? { |entry| entry[:status] != :matches })
        end

        private

        # 逐接口核对唯一邻居、现有描述和安全目标值，收集可审批的变更证据。
        # 只有唯一邻居和已识别的旧描述能形成变更；含糊、缺失或不安全输入保留为问题而不生成命令。
        def inspect_interface(interface, peers)
          peer = peers.first
          current = @descriptions[interface]
          row = { interface: peer.local_interface, neighbor: peer.neighbor_name, port: peer.neighbor_interface,
                  current: current, expected: nil, status: :unverified }
          @comparisons << row
          if peers.size != 1
            return reject_interface(row, :ambiguous_neighbor)
          end
          return reject_interface(row, peer.identity_issue) if peer.identity_issue
          return reject_interface(row, :interface_missing) unless @descriptions.key?(interface)

          proposed = @formatter.call(peer)
          Description.validate!(proposed)
          local = @strategy.configuration_interface(peer.local_interface)
          Description.validate_interface!(local)
          row.merge!(expected: proposed, status: compare_status(current, proposed, peer))
          @evidence[interface] = [peer.neighbor_name, peer.neighbor_interface, current]
          return if row[:status] == :matches

          @changes << Change.new(interface: local, old_description: current, new_description: proposed, neighbor: peer)
        rescue ArgumentError
          reject_interface(row, :unsafe_description)
        end

        # 将当前接口标记为不可核实，记录原因并排除其变更。
        def reject_interface(row, code)
          row[:reason] = code
          @issues << { interface: row[:interface], code: code }
          nil
        end

        # 区分描述一致、描述缺失与内容不一致。
        def compare_status(current, proposed, peer)
          return :matches if @description_matcher.call(current, proposed, peer)
          return :missing_description if current.empty?

          :content_mismatch
        end

        # 从已核实接口生成分阶段命令，并限定计划只覆盖这些接口。
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
