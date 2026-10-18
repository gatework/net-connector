# frozen_string_literal: true

require "ipaddr"
require_relative "device"
require_relative "batch"
require_relative "tftp/policy"

module Net
  module Connector
    module Netdisco
      # 固定一份清单上的选择结果与跳过原因，供预览和执行复用。
      Plan = Data.define(:mode, :inventory, :ready, :outcomes, :allow_fixed_name_reuse, :transfers) do
        # Data 只冻结对象自身；这里复制并冻结可能由调用方修改的计划容器。
        def initialize(mode:, inventory:, ready:, outcomes:, allow_fixed_name_reuse: false, transfers: nil)
          unless inventory.is_a?(Array) && ready.is_a?(Array) && outcomes.is_a?(Array)
            raise ArgumentError, "plan inventory, ready tasks, and outcomes must be Arrays"
          end

          tasks = ready.map { |task| task.is_a?(Array) ? task.dup.freeze : task }.freeze
          raise ArgumentError, "allow_fixed_name_reuse must be boolean" unless [true, false].include?(allow_fixed_name_reuse)

          if transfers.nil?
            policy = Tftp::Policy.new
            transfers = mode == :tftp ? inventory.select { |device| device.ready? && device.supports_backup?(mode: :tftp) }.to_h do |device|
              [device.host, policy.for(host: device.host, vendor: device.vendor)]
            end : {}
          end
          unless transfers.is_a?(Hash) && transfers.all? { |host, value| host.is_a?(String) && value.instance_of?(Tftp::Policy::Effective) }
            raise ArgumentError, "plan transfers must contain effective TFTP options by host"
          end
          transfer_copy = transfers.to_h { |host, value| [host.dup.freeze, value] }.freeze
          super(mode: mode, inventory: inventory.dup.freeze, ready: tasks, outcomes: outcomes.dup.freeze,
                allow_fixed_name_reuse: allow_fixed_name_reuse, transfers: transfer_copy)
        end

        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        # 按清单顺序返回选中的设备。
        def selected = ready.map(&:last)

        # 在任何设备 I/O 前校验完整快照，外部构造或修改的计划也必须遵守相同约束。
        def validate!
          raise ArgumentError, "plan mode must be backup or tftp" unless %i[backup tftp].include?(mode)
          unless inventory.all?(Device) && outcomes.size == inventory.size
            raise ArgumentError, "plan inventory and outcomes must have the same device slots"
          end
          validate_duplicate_hosts!
          validate_transfers!

          selected_indices = {}
          selected_filenames = {}
          previous_index = -1
          ready.each do |task|
            unless task.is_a?(Array) && task.size == 2 && task.first.is_a?(Integer)
              raise ArgumentError, "plan contains an invalid device task"
            end

            index, device = task
            unless index > previous_index && index < inventory.size && inventory[index].equal?(device) && device.ready? && device.supports_backup?(mode: mode)
              raise ArgumentError, "plan tasks must reference ready inventory devices in order"
            end
            validate_tftp_target!(device, selected_filenames) if mode == :tftp
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

        def validate_transfers!
          expected = mode == :tftp ? inventory.select { |device| device.ready? && device.supports_backup?(mode: :tftp) }.map(&:host).sort : []
          raise ArgumentError, "plan transfer options must match capable inventory devices" unless transfers.keys.sort == expected
        end

        def validate_tftp_target!(device, selected_filenames)
          transfer = transfers.fetch(device.host)
          Tftp::Policy.validate_effective!(transfer, host: device.host, vendor: device.vendor, path: device.tftp_filename) if transfer.server
          filename = target_key(device)
          if selected_filenames.key?(filename) && !(allow_fixed_name_reuse && device.vendor == :palo_alto)
            raise ArgumentError, "plan cannot upload multiple devices to one TFTP filename"
          end
          selected_filenames[filename] = true
        end

        def target_key(device) = [transfers[device.host]&.server, device.tftp_filename]

        # 外部快照也遵守清单入口的地址唯一性；采样不能把重复设备重新变为可执行。
        def validate_duplicate_hosts!
          issues_by_host = {}
          inventory.each do |device|
            next unless device.host

            host = IPAddr.new(device.host).to_s
            if issues_by_host.key?(host) && (issues_by_host[host] != :duplicate_host || device.issue != :duplicate_host)
              raise ArgumentError, "plan duplicate hosts must be marked as duplicate_host"
            end
            issues_by_host[host] = device.issue
          end
        end

        # 跳过结果不携带执行产物；文件冲突必须有本批次实际执行的目标作为依据。
        def valid_skipped_outcome?(result, device, selected_filenames)
          return false unless result.is_a?(Outcome) && result.device.equal?(device) && result.backup.nil? &&
                              result.error_code.nil? && result.error_type.nil? &&
                              result.started_at.nil? && result.finished_at.nil?

          return result.status == device.issue unless device.ready?

          return result.status == :unsupported_operation unless device.supports_backup?(mode: mode)

          result.status == :sample_limit ||
            (mode == :tftp && result.status == :remote_filename_collision && selected_filenames.key?(target_key(device)))
        end
      end
    end
  end
end
