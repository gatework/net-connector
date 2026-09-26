# frozen_string_literal: true

require "json"
require "yaml"

module Net
  module Connector
    module Netdisco
      # 命令行使用的无凭据 YAML 配置，环境变量优先。
      class ConfigFile
        FIELDS = {
          "netdisco" => { "url" => ["NETDISCO_URL", :string],
                          "page_size" => ["NETDISCO_PAGE_SIZE", :integer] },
          "backup" => { "directory" => ["NET_CONNECTOR_BACKUP_DIRECTORY", :string],
                        "concurrency" => ["NET_CONNECTOR_CONCURRENCY", :integer],
                        "limit_per_vendor" => ["NET_CONNECTOR_SAMPLE_PER_VENDOR", :integer] },
          "inventory" => { "include_hosts" => ["NET_CONNECTOR_INCLUDE_HOSTS", :list],
                           "exclude_hosts" => ["NET_CONNECTOR_EXCLUDE_HOSTS", :list],
                           "include_vendors" => ["NET_CONNECTOR_INCLUDE_VENDORS", :list],
                           "vendor_overrides" => ["NET_CONNECTOR_VENDOR_OVERRIDES", :json],
                           "host_overrides" => ["NET_CONNECTOR_HOST_OVERRIDES", :json],
                           "device_rules" => ["NET_CONNECTOR_DEVICE_RULES", :json] },
          "ssh" => { "protocol" => ["NET_CONNECTOR_PROTOCOL", :string],
                     "known_hosts" => ["NET_CONNECTOR_KNOWN_HOSTS", :string],
                     "host_key_policy" => ["NET_CONNECTOR_HOST_KEY_POLICY", :string],
                     "log_directory" => ["NET_CONNECTOR_LOG_DIRECTORY", :string],
                     "log_level" => ["NET_CONNECTOR_LOG_LEVEL", :string] },
          "tftp" => { "server" => ["TFTP_HOST", :string],
                      "vrfs" => ["NET_CONNECTOR_TFTP_VRFS", :json] }
        }.freeze

        # 安全读取 YAML 配置并映射到环境变量格式。
        def self.load(path)
          raise ArgumentError, "config path must be a nonempty String" unless path.is_a?(String) && !path.empty?

          document = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
          raise ArgumentError, "config must be a YAML mapping" unless document.is_a?(Hash)

          unknown_sections = document.keys - FIELDS.keys
          raise ArgumentError, "unknown config sections: #{unknown_sections.join(", ")}" unless unknown_sections.empty?

          document.each_with_object({}) do |(section, values), result|
            fields = FIELDS.fetch(section)
            raise ArgumentError, "#{section} must be a mapping" unless values.is_a?(Hash)

            unknown = values.keys - fields.keys
            raise ArgumentError, "unknown #{section} settings: #{unknown.join(", ")}" unless unknown.empty?

            values.each do |name, value|
              key, type = fields.fetch(name)
              result[key] = encode(section, name, type, value)
            end
          end
        rescue Psych::Exception => error
          raise ArgumentError, "invalid YAML config (#{error.class})"
        end

        # 按字段类型校验并编码单项配置。
        def self.encode(section, name, type, value)
          case type
          when :string
            raise ArgumentError, "#{section}.#{name} must be a nonempty String" unless value.is_a?(String) && !value.strip.empty?

            value
          when :integer
            raise ArgumentError, "#{section}.#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

            value.to_s
          when :list
            unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? && !item.include?(",") }
              raise ArgumentError, "#{section}.#{name} must be a list of strings without commas"
            end

            value.join(",")
          when :json
            expected = name == "device_rules" ? Array : Hash
            raise ArgumentError, "#{section}.#{name} must be a #{expected}" unless value.is_a?(expected)

            JSON.generate(value)
          end
        end

        private_class_method :encode
      end
    end
  end
end
