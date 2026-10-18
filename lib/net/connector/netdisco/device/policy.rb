# frozen_string_literal: true

require "ipaddr"
require_relative "../device"

module Net
  module Connector
    module Netdisco
      class Device
        # 文本策略按厂商默认和精确设备地址选择；nil 覆盖表示回到设备协议缺省。
        # 只保存已校验的不可变值，不保存验证回调、设备对象或原始配置容器。
        class Policy
          def initialize(values, vendors:, &validate)
            raise ArgumentError, "vendor policy must be a mapping" unless values.is_a?(Hash)
            raise ArgumentError, "vendor policy requires a validator" unless validate

            @entries = values.each_with_object({}) do |(key, value), entries|
              vendor = vendors.find { |candidate| key == candidate || key == candidate.to_s }
              raise ArgumentError, "vendor policy contains an unsupported vendor" unless vendor
              raise ArgumentError, "vendor policy contains duplicate vendor keys" if entries.key?(vendor)

              entries[vendor] = normalize_entry(value, validate)
            end.freeze
            freeze
          end

          def for(vendor:, host:)
            entry = @entries[vendor]
            return nil unless entry

            entry.fetch(:hosts).fetch(address(host)) { entry[:default] }
          end

          def to_h = @entries

          private

          def normalize_entry(value, validate)
            return { default: normalize_value(value, validate), hosts: {}.freeze }.freeze unless value.is_a?(Hash)

            names = value.keys.map(&:to_s)
            unless (names - %w[default hosts]).empty? && names.uniq.size == names.size
              raise ArgumentError, "vendor policy accepts only default and hosts"
            end
            fields = value.transform_keys(&:to_sym)
            hosts = fields.fetch(:hosts, {})
            raise ArgumentError, "vendor policy hosts must be a mapping" unless hosts.is_a?(Hash)

            overrides = hosts.each_with_object({}) do |(host, item), result|
              key = address(host)
              raise ArgumentError, "vendor policy contains duplicate normalized addresses" if result.key?(key)

              result[key] = normalize_value(item, validate)
            end.freeze
            { default: normalize_value(fields[:default], validate), hosts: overrides }.freeze
          end

          def normalize_value(value, validate)
            raise ArgumentError, "vendor policy values must be strings or nil" unless value.nil? || value.is_a?(String)

            validate.call(value)
            value&.dup&.freeze
          end

          def address(host)
            unless host.is_a?(String) && !host.empty? && !host.include?("/") && !host.include?("%")
              raise ArgumentError, "vendor policy hosts must be exact IP addresses"
            end
            IPAddr.new(host).to_s.freeze
          rescue IPAddr::Error
            raise ArgumentError, "vendor policy hosts must be exact IP addresses", cause: nil
          end
        end
      end
    end
  end
end
