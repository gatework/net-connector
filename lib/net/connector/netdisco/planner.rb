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
          selected_indices = selected.to_h { |_device, index| [index, true] }
          filenames = {}
          if mode == :tftp
            # 先按采样顺序保留每个目标的首台设备，再按清单顺序输出结果。
            selected.each { |device, index| filenames[device.tftp_filename] ||= index }
          end
          outcomes = Array.new(@inventory.size)
          ready = @inventory.each_with_index.filter_map do |device, index|
            if !device.ready?
              outcomes[index] = skipped(device, device.issue)
              nil
            elsif !selected_indices.key?(index)
              outcomes[index] = skipped(device, :sample_limit)
              nil
            elsif mode == :tftp && filenames.fetch(device.tftp_filename) != index
              outcomes[index] = skipped(device, :remote_filename_collision)
              nil
            else
              [index, device].freeze
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
