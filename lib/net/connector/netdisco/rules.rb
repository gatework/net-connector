# frozen_string_literal: true

require "ipaddr"

module Net
  module Connector
    module Netdisco
      # 将 Netdisco 标签映射到连接器并筛选清单。
      class Rules
        # 校验并保存清单过滤和厂商映射规则。
        def initialize(include_hosts: [], exclude_hosts: [], include_vendors: [], vendor_overrides: {},
                       host_overrides: {}, mappings: [])
          @include_hosts = string_list(include_hosts)
          @exclude_hosts = string_list(exclude_hosts)
          @include_vendors = vendor_list(include_vendors)
          @vendor_overrides = vendor_mapping(vendor_overrides)
          @host_overrides = host_mapping(host_overrides)
          @mappings = device_mappings(mappings)
        end

        # 校验允许使用的厂商列表。
        def vendor_list(include_vendors)
          raise ArgumentError, "include_vendors must be an Array" unless include_vendors.is_a?(Array)

          vendors = include_vendors.map do |vendor|
            raise ArgumentError, "include_vendors contains an invalid value" unless vendor.is_a?(String) || vendor.is_a?(Symbol)

            vendor.to_sym
          end.freeze
          unless vendors.all? { |vendor| Net::Connector.vendors.include?(vendor) }
            raise ArgumentError, "include_vendors contains an unsupported connector"
          end
          vendors
        end

        # 将清单厂商标签映射为受支持的连接器。
        def vendor_mapping(vendor_overrides)
          unless vendor_overrides.is_a?(Hash)
            raise ArgumentError, "vendor_overrides must be a Hash"
          end
          vendor_overrides.to_h do |label, vendor|
            unless label.is_a?(String) && vendor.is_a?(String) && !label.empty?
              raise ArgumentError, "vendor_overrides must map labels to connector names"
            end
            key = normalize(label)
            value = vendor.to_sym
            raise ArgumentError, "vendor_overrides contains an unsupported connector" unless Net::Connector.vendors.include?(value)

            [key, value]
          end.freeze
        end

        # 按规范化管理地址覆盖厂商，拒绝网段和无效地址。
        def host_mapping(host_overrides)
          raise ArgumentError, "host_overrides must be a Hash" unless host_overrides.is_a?(Hash)

          host_overrides.to_h do |host, vendor|
            unless host.is_a?(String) && !host.include?("/") && vendor.is_a?(String)
              raise ArgumentError, "host_overrides must map IP addresses to connector names"
            end
            begin
              address = IPAddr.new(host).to_s
            rescue IPAddr::Error
              raise ArgumentError, "host_overrides contains an invalid IP address"
            end
            connector = vendor.to_sym
            raise ArgumentError, "host_overrides contains an unsupported connector" unless Net::Connector.vendors.include?(connector)

            [address, connector]
          end.freeze
        end

        # 型号映射仅接受已声明字段，并冻结每条规则。
        def device_mappings(mappings)
          raise ArgumentError, "mappings must be an Array" unless mappings.is_a?(Array)

          mappings.map do |rule|
            unless rule.is_a?(Hash) && rule["vendor"].is_a?(String) && !rule["vendor"].empty? &&
                   rule["connector"].is_a?(String) &&
                   (rule.keys - %w[vendor os model_prefix connector]).empty? &&
                   %w[os model_prefix].all? { |key| rule[key].nil? || rule[key].is_a?(String) }
              raise ArgumentError, "each mapping requires vendor and connector strings"
            end
            connector = rule.fetch("connector").to_sym
            raise ArgumentError, "mapping contains an unsupported connector" unless Net::Connector.vendors.include?(connector)

            { vendor: normalize(rule.fetch("vendor")), os: rule["os"] && normalize(rule["os"]),
              model_prefix: rule["model_prefix"] && normalize(rule["model_prefix"]), connector: connector }.freeze
          end.freeze
        end

        private :vendor_list, :vendor_mapping, :host_mapping, :device_mappings

        # 根据地址、显式规则和厂商信息识别连接器。
        def resolve(row)
          begin
            address = IPAddr.new(row["ip"]).to_s
            return @host_overrides.fetch(address) if @host_overrides.key?(address)
          rescue IPAddr::Error, TypeError
            # 无效的管理地址交由 Device.from_row 标记。
          end
          label = normalize(row["vendor"])
          os = normalize(row["os"])
          model = normalize(row["model"])
          match = @mappings.find do |rule|
            rule[:vendor] == label && (rule[:os].nil? || rule[:os] == os) &&
              (rule[:model_prefix].nil? || model.start_with?(rule[:model_prefix]))
          end
          return match[:connector] if match
          return @vendor_overrides[label] if @vendor_overrides.key?(label)

          # 厂商标签可能陈旧；仅在操作系统和带品牌型号同时确认时纠正。
          return h3c_connector(os, model) if os == "comware" && model.match?(/\Ah3c\s+\S/)

          case label
          when /\bh3c\b/ then h3c_connector(os, model)
          when /\bcisco\b/
            return :cisco_nxos if os.match?(/nx\s*os|nexus/) || model.match?(/\bnexus\b|\bn\s*[3579]k\b/)
            :cisco_ios if os.match?(/\bios\b|\bios\s*xe\b/)
          when /\bradware\b/ then :radware
          when /palo\s*alto|paloalto/ then :palo_alto
          when /\bhuawei\b/ then :huawei
          when /\bhillstone\b/ then :hillstone
          end
        end

        # 判断设备是否通过地址和厂商过滤。
        def selected?(host, vendor)
          return false if @exclude_hosts.include?(host)
          return false if !@include_hosts.empty? && !@include_hosts.include?(host)
          return false if !@include_vendors.empty? && !@include_vendors.include?(vendor)

          true
        end

        private

        def h3c_connector(os, model)
          wireless = os.match?(/wireless|wlan/) || model.match?(/\A(?:h3c\s+)?(?:wx|ac)\s*\d/)
          wireless ? :h3c_wireless : :h3c
        end

        # 校验并标准化管理地址列表。
        def string_list(values)
          raise ArgumentError, "host lists must be Arrays" unless values.is_a?(Array)

          values.map do |value|
            raise ArgumentError, "host list entries must be Strings" unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "host list entries must be IP addresses" if value.include?("/")

            IPAddr.new(value).to_s.freeze
          rescue IPAddr::Error
            raise ArgumentError, "host list entries must be IP addresses"
          end.freeze
        end

        # 将设备标签转为便于匹配的小写词串。
        def normalize(value) = value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
      end
    end
  end
end
