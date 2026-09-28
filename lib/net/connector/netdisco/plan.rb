# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      # 固定一份清单上的选择结果与跳过原因，供预览和执行复用。
      Plan = Data.define(:mode, :inventory, :ready, :outcomes, :allow_fixed_name_reuse) do
        # Data 只冻结对象自身；这里复制并冻结可能由调用方修改的计划容器。
        def initialize(mode:, inventory:, ready:, outcomes:, allow_fixed_name_reuse: false)
          unless inventory.is_a?(Array) && ready.is_a?(Array) && outcomes.is_a?(Array)
            raise ArgumentError, "plan inventory, ready tasks, and outcomes must be Arrays"
          end

          tasks = ready.map { |task| task.is_a?(Array) ? task.dup.freeze : task }.freeze
          raise ArgumentError, "allow_fixed_name_reuse must be boolean" unless [true, false].include?(allow_fixed_name_reuse)

          super(mode: mode, inventory: inventory.dup.freeze, ready: tasks, outcomes: outcomes.dup.freeze,
                allow_fixed_name_reuse: allow_fixed_name_reuse)
        end

        # 按清单顺序返回选中的设备。
        def selected = ready.map(&:last)

        # 在任何设备 I/O 前校验完整快照，外部构造或修改的计划也必须遵守相同约束。
        def validate!
          raise ArgumentError, "plan mode must be backup or tftp" unless %i[backup tftp].include?(mode)
          unless inventory.all?(Device) && outcomes.size == inventory.size
            raise ArgumentError, "plan inventory and outcomes must have the same device slots"
          end

          selected_indices = {}
          selected_filenames = {}
          previous_index = -1
          ready.each do |task|
            unless task.is_a?(Array) && task.size == 2 && task.first.is_a?(Integer)
              raise ArgumentError, "plan contains an invalid device task"
            end

            index, device = task
            unless index > previous_index && index < inventory.size && inventory[index].equal?(device) && device.ready?
              raise ArgumentError, "plan tasks must reference ready inventory devices in order"
            end
            if mode == :tftp
              filename = device.tftp_filename
              if selected_filenames.key?(filename) && !(allow_fixed_name_reuse && device.vendor == :palo_alto)
                raise ArgumentError, "plan cannot upload multiple devices to one TFTP filename"
              end

              selected_filenames[filename] = true
            end
            selected_indices[index] = true
            previous_index = index
          end

          inventory.each_with_index do |device, index|
            result = outcomes[index]
            next if selected_indices[index] && result.nil?

            unless !selected_indices[index] && valid_skipped_outcome?(result, device, selected_filenames)
              raise ArgumentError, "plan outcome does not match its inventory slot"
            end
          end
          self
        end

        private

        # 跳过结果不携带执行产物；文件冲突必须有本批次实际执行的目标作为依据。
        def valid_skipped_outcome?(result, device, selected_filenames)
          return false unless result.is_a?(Outcome) && result.device.equal?(device) && result.backup.nil? &&
                              result.error_code.nil? && result.error_type.nil? &&
                              result.started_at.nil? && result.finished_at.nil?

          return result.status == device.issue unless device.ready?

          result.status == :sample_limit ||
            (mode == :tftp && result.status == :remote_filename_collision && selected_filenames.key?(device.tftp_filename))
        end
      end
    end
  end
end
