# frozen_string_literal: true

require_relative "settings"
require_relative "device"

module Net
  module Connector
    module Netdisco
      # 只读取、归一化及标记清单；凭据、连接、操作和报告由宿主拥有。
      class Catalog
        attr_reader :status

        def initialize(settings: Settings.new, inventory: nil, rules: nil)
          @settings, @inventory, @rules = settings, inventory, rules
        end

        # 使用调用方固定的同批策略，保留被过滤、无效及重复的记录。
        def devices(policy:, force_refresh: false)
          @status = nil
          raise ArgumentError, "force_refresh must be true or false" unless [true, false].include?(force_refresh)

          inventory = @inventory || @settings.inventory(policy: policy)
          cache_mode = policy.inventory_cache_mode
          raise ArgumentError, "cache-only cannot force refresh" if cache_mode == :only && force_refresh
          if cache_mode == :only && !inventory.is_a?(Inventory::Cache)
            raise Inventory::Error.new("validated inventory cache is unavailable", code: :cache_unavailable), cause: nil
          end
          rows = if inventory.is_a?(Inventory::Cache)
                   inventory.devices(force_refresh: force_refresh, cache_mode: cache_mode)
                 else
                   inventory.devices
                 end
          @status = if inventory.is_a?(Inventory::Cache)
                                { source: inventory.status, fetched_at: inventory.fetched_at,
                                  refresh_error_code: inventory.refresh_error_code, write_error_type: inventory.write_error_type }.freeze
                              else
                                { source: :uncached }.freeze
                              end
          raise Inventory::Error, "Netdisco returned an invalid device inventory" unless rows.is_a?(Array)

          rules = @rules || policy.rules
          devices = rows.map { |row| Device.from_row(row, rules: rules) }
          host_counts = devices.each_with_object(Hash.new(0)) { |device, counts| counts[device.host] += 1 if device.host }
          devices.map { |device| host_counts[device.host] > 1 ? device.with(issue: :duplicate_host) : device }.freeze
        end

        def inspect = "#<#{self.class}>"
        alias to_s inspect
        def pretty_print(printer) = printer.text(inspect)
      end
    end
  end
end
