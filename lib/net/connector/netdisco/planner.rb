# frozen_string_literal: true

require_relative "plan"
require_relative "batch"

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
          # 默认全量不构造采样任务副本或逐设备选择索引；只保留最终计划需要的槽位。
          selected_tasks = sample_tasks(limit_per_vendor)
          selected_indices = selected_tasks&.to_h { |index, _device| [index, true] }
          first_index_by_filename = mode == :tftp ? tftp_target_indices(selected_tasks) : {}
          outcomes = Array.new(@inventory.size)
          ready = @inventory.each_with_index.filter_map do |device, index|
            if !device.ready?
              outcomes[index] = skipped(device, device.issue)
              nil
            elsif selected_indices && !selected_indices.key?(index)
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

        # 只有显式采样才分组；厂商组内仍按管理地址选择，与全量输出顺序分开。
        def sample_tasks(limit)
          return unless limit

          tasks = @inventory.each_with_index.filter_map { |device, index| [index, device] if device.ready? }
          tasks.group_by { |_index, device| device.vendor }.values.flat_map do |group|
            group.min_by(limit) { |_index, device| device.host }
          end
        end

        # 采样模式按采样顺序仲裁目标，全量模式直接扫描清单；输出仍保留清单顺序。
        def tftp_target_indices(selected_tasks)
          found = {}
          if selected_tasks
            selected_tasks.each { |index, device| found[device.tftp_filename] ||= index }
          else
            @inventory.each_with_index { |device, index| found[device.tftp_filename] ||= index if device.ready? }
          end
          found
        end

        # 构建计划阶段无需设备连接的跳过结果。
        def skipped(device, status)
          Outcome.new(device: device, status: status, backup: nil, error_code: nil, error_type: nil)
        end
      end
    end
  end
end
