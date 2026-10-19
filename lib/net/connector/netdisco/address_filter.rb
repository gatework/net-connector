# frozen_string_literal: true

require "ipaddr"

module Net
  module Connector
    module Netdisco
      # 精确地址用索引，网段和范围只保存端点；绝不展开地址或发起扫描。
      class AddressFilter
        # 规范化精确地址并合并同族网段区间，不展开大型地址范围。
        def initialize(values)
          raise ArgumentError, "host lists must be Arrays" unless values.is_a?(Array)

          exact = {}
          ranges = {}
          values.each do |value|
            raise ArgumentError, "host entries must be nonempty strings" unless value.is_a?(String) && !value.empty?

            if value.include?("/") || value.split("%", 2).first.include?("-")
              first, last = endpoints(value)
              (ranges[first.family] ||= []) << [first.to_i, last.to_i]
            else
              exact[IPAddr.new(value).to_s.freeze] = true
            end
          end
          @exact = exact.freeze
          @ranges = ranges.transform_values { |items| merge_ranges(items) }.freeze
          freeze
        rescue IPAddr::Error
          raise ArgumentError, "host entries must be IP addresses, networks or ordered ranges", cause: nil
        end

        # 判断是否没有任何地址过滤项。
        def empty? = @exact.empty? && @ranges.empty?

        # 先查精确地址索引，再二分查找已合并区间，判断设备是否匹配。
        def include?(host)
          return false if empty?
          return true if @exact.key?(host)
          return false unless host.is_a?(String) && !host.empty?

          address = IPAddr.new(host)
          return true if @exact.key?(address.to_s)

          intervals = @ranges[address.family]
          return false unless intervals

          value = address.to_i
          interval = intervals.bsearch { |_, last| last >= value }
          interval && interval.first <= value ? true : false
        rescue IPAddr::Error
          false
        end

        private

        # 将网段或有序地址范围解析为同地址族的起止端点。
        def endpoints(value)
          if value.include?("/")
            range = IPAddr.new(value).to_range
            return [range.begin, range.end]
          end
          first, last = value.split("-", 2)
          first = IPAddr.new(first)
          if first.ipv4? && last&.match?(/\A\d+\z/)
            last = first.to_s.rpartition(".").first + ".#{last}"
          end
          last = IPAddr.new(last)
          unless first.family == last.family && first.to_i <= last.to_i && !(first.ipv6? && (first.zone_id || last.zone_id))
            raise ArgumentError, "host ranges require ordered endpoints of the same address family", cause: nil
          end
          [first, last]
        end

        # 合并重叠范围，使每台设备匹配的成本不随网段大小增长。
        def merge_ranges(items)
          merged = []
          items.sort.each do |first, last|
            if !merged.empty? && first <= merged.last.last + 1
              merged.last[1] = [merged.last.last, last].max
            else
              merged << [first, last]
            end
          end
          merged.each(&:freeze).freeze
        end
      end
    end
  end
end
