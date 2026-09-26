# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      # 固定一份清单上的选择结果与跳过原因，供预览和执行复用。
      Plan = Data.define(:mode, :inventory, :ready, :outcomes) do
        # Data 只冻结对象自身；这里复制并冻结可能由调用方修改的计划容器。
        def initialize(mode:, inventory:, ready:, outcomes:)
          unless inventory.is_a?(Array) && ready.is_a?(Array) && outcomes.is_a?(Array)
            raise ArgumentError, "plan inventory, ready tasks, and outcomes must be Arrays"
          end

          tasks = ready.map { |task| task.is_a?(Array) ? task.dup.freeze : task }.freeze
          super(mode: mode, inventory: inventory.dup.freeze, ready: tasks, outcomes: outcomes.dup.freeze)
        end

        # 按清单顺序返回选中的设备。
        def selected = ready.map(&:last)
      end

      # 根据设备就绪状态、厂商采样及远端文件冲突建立备份计划。
      class Planner
        # 保存本次规划使用的清单快照。
        def initialize(inventory)
          @inventory = inventory.dup.freeze
        end

        # 生成本地或 TFTP 备份计划，明确记录每台未执行设备的原因。
        def call(mode:, limit_per_vendor:)
          self.class.validate_limit!(limit_per_vendor)
          candidates = @inventory.each_with_index.select { |device, _index| device.ready? }
          selected = if limit_per_vendor
                       candidates.group_by { |device, _index| device.vendor }.values.flat_map do |entries|
                         entries.sort_by { |device, _index| device.host }.first(limit_per_vendor)
                       end
                     else
                       candidates
                     end
          # PAN-OS 导出使用固定远端文件名，同批只允许一台设备写入。
          palo_alto_index = selected.find { |device, _index| device.vendor == :palo_alto }&.last if mode == :tftp
          selected_indices = selected.to_h { |_device, index| [index, true] }
          outcomes = Array.new(@inventory.size)
          ready = @inventory.each_with_index.filter_map do |device, index|
            if !device.ready?
              outcomes[index] = skipped(device, device.issue)
              nil
            elsif mode == :tftp && device.vendor == :palo_alto && index != palo_alto_index
              outcomes[index] = skipped(device, :remote_filename_collision)
              nil
            elsif selected_indices.key?(index)
              [index, device].freeze
            else
              outcomes[index] = skipped(device, :sample_limit)
              nil
            end
          end
          Plan.new(mode: mode, inventory: @inventory, ready: ready.freeze, outcomes: outcomes.freeze)
        end

        # 限制单厂商采样数，空值表示选择所有就绪设备。
        def self.validate_limit!(limit)
          return if limit.nil? || (limit.is_a?(Integer) && (1..5).cover?(limit))

          raise ArgumentError, "limit_per_vendor must be nil or an Integer in 1..5"
        end

        private

        # 构建计划阶段无需设备连接的跳过结果。
        def skipped(device, status)
          Outcome.new(device: device, status: status, backup: nil, error_code: nil, error_type: nil)
        end
      end
    end
  end
end
