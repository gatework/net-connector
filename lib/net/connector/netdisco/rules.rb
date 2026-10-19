# frozen_string_literal: true

require "ipaddr"
require_relative "../../connector"
require_relative "address_filter"

module Net
  module Connector
    module Netdisco
      # 将 Netdisco 标签映射到连接器并筛选清单。
      class Rules
        # 校验并保存清单过滤和厂商映射规则。
        def initialize(include_hosts: [], exclude_hosts: [], include_vendors: [], vendor_overrides: {},
                       host_overrides: {}, mappings: [], include_names: [], exclude_names: [],
                       name_match: :contains, exclude_vendors: [])
          @include_hosts = AddressFilter.new(include_hosts)
          @exclude_hosts = AddressFilter.new(exclude_hosts)
          @include_vendors = vendor_list(include_vendors)
          @exclude_vendors = vendor_list(exclude_vendors)
          @include_names = name_list(include_names)
          @exclude_names = name_list(exclude_names)
          unless (name_match.is_a?(String) || name_match.is_a?(Symbol)) && %w[contains prefix glob].include?(name_match.to_s)
            raise ArgumentError, "name_match must be contains, prefix or glob"
          end
          @name_match = name_match.to_sym
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
          vendor_overrides.each_with_object({}) do |(label, vendor), mapping|
            unless label.is_a?(String) && vendor.is_a?(String) && !label.empty?
              raise ArgumentError, "vendor_overrides must map labels to connector names"
            end
            key = normalize(label)
            raise ArgumentError, "vendor_overrides labels must remain nonempty after normalization" if key.empty?

            value = vendor.to_sym
            raise ArgumentError, "vendor_overrides contains an unsupported connector" unless Net::Connector.vendors.include?(value)
            if mapping.key?(key) && mapping[key] != value
              raise ArgumentError, "vendor_overrides contains conflicting normalized labels"
            end

            mapping[key] = value
          end.freeze
        end

        # 按规范化管理地址覆盖厂商，拒绝网段和无效地址。
        def host_mapping(host_overrides)
          raise ArgumentError, "host_overrides must be a Hash" unless host_overrides.is_a?(Hash)

          host_overrides.each_with_object({}) do |(host, vendor), mapping|
            unless host.is_a?(String) && !host.include?("/") && vendor.is_a?(String)
              raise ArgumentError, "host_overrides must map IP addresses to connector names"
            end
            begin
              address = IPAddr.new(host).to_s
            rescue IPAddr::Error
              raise ArgumentError, "host_overrides contains an invalid IP address", cause: nil
            end
            connector = vendor.to_sym
            raise ArgumentError, "host_overrides contains an unsupported connector" unless Net::Connector.vendors.include?(connector)
            if mapping.key?(address) && mapping[address] != connector
              raise ArgumentError, "host_overrides contains conflicting normalized IP addresses"
            end

            mapping[address] = connector
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
            vendor = normalize(rule.fetch("vendor"))
            raise ArgumentError, "mapping vendor must remain nonempty after normalization" if vendor.empty?

            { vendor: vendor, os: rule["os"] && normalize(rule["os"]),
              model_prefix: rule["model_prefix"] && normalize(rule["model_prefix"]), connector: connector }.freeze
          end.freeze
        end

        private :vendor_list, :vendor_mapping, :host_mapping, :device_mappings

        # 根据地址、显式规则和厂商信息识别连接器。
        def resolve(row)
          unless @host_overrides.empty?
            begin
              address = IPAddr.new(row["ip"]).to_s
              return @host_overrides.fetch(address) if @host_overrides.key?(address)
            rescue IPAddr::Error, TypeError
              # 无效的管理地址交由 Device.from_row 标记。
            end
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
          when /\bcentec\b/ then :centec
          when /\btopsec\b/ then :topsec
          when /\bfortinet\b|\bfortigate\b/
            :fortinet if os == "fortios" || label.match?(/\bfortigate\b/) || model.match?(/\A(?:fortigate|fgt)[\s-]*\d/i)
          when /\bjuniper\b/
            :juniper if os.match?(/\bjunos\b/)
          end
        end

        # 判断设备是否通过地址和厂商过滤。
        def selected?(host, vendor, name: nil)
          return false if @exclude_hosts.include?(host)
          return false if !@include_hosts.empty? && !@include_hosts.include?(host)
          return false if @exclude_vendors.include?(vendor)
          return false if !@include_vendors.empty? && !@include_vendors.include?(vendor)

          return true if @include_names.empty? && @exclude_names.empty?

          value = name.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").downcase
          return false if @exclude_names.any? { |pattern| name_matches?(pattern, value) }
          return false if !@include_names.empty? && @include_names.none? { |pattern| name_matches?(pattern, value) }

          true
        end

        private

        # 结合操作系统和型号识别 H3C 交换机或无线控制器。
        def h3c_connector(os, model)
          wireless = os.match?(/wireless|wlan/) || model.match?(/\A(?:h3c\s+)?(?:wx|ac)\s*\d/)
          wireless ? :h3c_wireless : :h3c
        end

        # 校验名称过滤项为有效非空文本，统一小写并去重冻结。
        def name_list(values)
          unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) && !value.strip.empty? && value.valid_encoding? }
            raise ArgumentError, "name filters must be arrays of nonempty strings"
          end
          values.map { |value| value.downcase.freeze }.uniq.freeze
        end

        # 按包含、前缀或通配符模式匹配已规范化的设备名称。
        def name_matches?(pattern, value)
          case @name_match
          when :contains then value.include?(pattern)
          when :prefix then value.start_with?(pattern)
          when :glob then File.fnmatch?(pattern, value)
          end
        end

        # 将设备标签转为便于匹配的小写词串。
        def normalize(value) = value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
      end
    end
  end
end
