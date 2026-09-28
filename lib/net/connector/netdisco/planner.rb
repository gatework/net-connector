# frozen_string_literal: true

require_relative "plan"

module Net
  module Connector
    module Netdisco
      # 根据设备就绪状态、厂商采样及远端文件冲突建立备份计划。
      class Planner
        # 保存本次规划使用的清单快照。
        def initialize(inventory)
          @inventory = inventory.dup.freeze
        end

        # 生成本地或 TFTP 备份计划，明确记录每台未执行设备的原因。
        def call(mode:, limit_per_vendor:, allow_fixed_name_reuse: false)
          self.class.validate_limit!(limit_per_vendor)
          ready_tasks = @inventory.each_with_index.filter_map do |device, index|
            [index, device] if device.ready?
          end
          selected_tasks = if limit_per_vendor
                             ready_tasks.group_by { |_index, device| device.vendor }.values.flat_map do |tasks|
                               tasks.sort_by { |_index, device| device.host }.first(limit_per_vendor)
                             end
                           else
                             ready_tasks
                           end
          selected_indices = selected_tasks.to_h { |index, _device| [index, true] }
          first_index_by_filename = {}
          if mode == :tftp
            # 先按采样顺序保留每个目标的首台设备，再按清单顺序输出结果。
            selected_tasks.each { |index, device| first_index_by_filename[device.tftp_filename] ||= index }
          end
          outcomes = Array.new(@inventory.size)
          ready = @inventory.each_with_index.filter_map do |device, index|
            if !device.ready?
              outcomes[index] = skipped(device, device.issue)
              nil
            elsif !selected_indices.key?(index)
              outcomes[index] = skipped(device, :sample_limit)
              nil
            elsif mode == :tftp && first_index_by_filename.fetch(device.tftp_filename) != index &&
                  !(allow_fixed_name_reuse && device.vendor == :palo_alto)
              outcomes[index] = skipped(device, :remote_filename_collision)
              nil
            else
              [index, device].freeze
            end
          end
          Plan.new(mode: mode, inventory: @inventory, ready: ready.freeze, outcomes: outcomes.freeze,
                   allow_fixed_name_reuse: allow_fixed_name_reuse)
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
