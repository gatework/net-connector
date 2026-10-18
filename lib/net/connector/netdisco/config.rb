# frozen_string_literal: true

require "json"
require "yaml"

module Net
  module Connector
    module Netdisco
      # 公开 YAML 配置的字段、解析和类型校验；凭据由环境或调用方提供。
      module Config
        FIELDS = {
          "netdisco" => { "cache_directory" => ["ND_CACHE_DIRECTORY", :string],
                          "cache_ttl" => ["ND_CACHE_TTL", :number],
                          "cache_enabled" => ["ND_CACHE_ENABLED", :boolean],
                          "cache_mode" => ["ND_CACHE_MODE", :string],
                          "source" => ["ND_SOURCE", :string],
                          "query" => ["ND_QUERY", :string],
                          "query_params" => ["ND_QUERY_PARAMS", :json_array],
                          "url" => ["ND_URL", :string],
                          "page_size" => ["ND_PAGE_SIZE", :integer],
                          "max_pages" => ["ND_MAX_PAGES", :integer],
                          "max_response_bytes" => ["ND_MAX_RESPONSE_BYTES", :integer],
                          "max_inventory_bytes" => ["ND_MAX_INVENTORY_BYTES", :integer],
                          "max_devices" => ["ND_MAX_DEVICES", :integer],
                          "inventory_timeout" => ["ND_INVENTORY_TIMEOUT", :number],
                          "allow_insecure_http" => ["ND_ALLOW_INSECURE_HTTP", :boolean],
                          "db_port" => ["ND_DB_PORT", :integer],
                          "db_sslmode" => ["ND_DB_SSLMODE", :string],
                          "db_sslrootcert" => ["ND_DB_SSLROOTCERT", :string],
                          "db_connect_timeout" => ["ND_DB_CONNECT_TIMEOUT", :integer] },
          "topology" => { "mode" => ["NC_TOPOLOGY_MODE", :string],
                          "cache_mode" => ["NC_TOPOLOGY_CACHE_MODE", :string],
                          "concurrency" => ["NC_TOPOLOGY_CONCURRENCY", :integer],
                          "directory" => ["NC_TOPOLOGY_DIRECTORY", :string],
                          "limit" => ["NC_TOPOLOGY_LIMIT", :optional_integer],
                          "description_format" => ["NC_TOPOLOGY_DESCRIPTION_FORMAT", :string],
                          "abbreviate_ports" => ["NC_TOPOLOGY_ABBREVIATE", :boolean],
                          "lowercase_ports" => ["NC_TOPOLOGY_LOWERCASE", :boolean] },
          "backup" => { "directory" => ["NC_BACKUP_DIRECTORY", :string],
                        "concurrency" => ["NC_CONCURRENCY", :integer],
                        "limit_per_vendor" => ["NC_SAMPLE_PER_VENDOR", :integer] },
          "inventory" => { "include_hosts" => ["NC_INCLUDE_HOSTS", :list],
                           "exclude_hosts" => ["NC_EXCLUDE_HOSTS", :list],
                           "include_names" => ["NC_INCLUDE_NAMES", :list],
                           "exclude_names" => ["NC_EXCLUDE_NAMES", :list],
                           "name_match" => ["NC_NAME_MATCH", :string],
                           "exclude_vendors" => ["NC_EXCLUDE_VENDORS", :list],
                           "include_vendors" => ["NC_INCLUDE_VENDORS", :list],
                           "vendor_overrides" => ["NC_VENDOR_OVERRIDES", :json],
                           "host_overrides" => ["NC_HOST_OVERRIDES", :json],
                           "device_rules" => ["NC_DEVICE_RULES", :json] },
          "ssh" => { "protocol" => ["NC_PROTOCOL", :string],
                     "vendor_protocols" => ["NC_VENDOR_PROTOCOLS", :json],
                     "max_script_output_bytes" => ["NC_MAX_SCRIPT_OUTPUT_BYTES", :optional_integer],
                     "known_hosts" => ["NC_KNOWN_HOSTS", :string],
                     "host_key_policy" => ["NC_HOST_KEY_POLICY", :string],
                     "log_directory" => ["NC_LOG_DIRECTORY", :string],
                     "log_level" => ["NC_LOG_LEVEL", :string] },
          "tftp" => { "server" => ["NC_TFTP_HOST", :string],
                      "verification_root" => ["NC_TFTP_ROOT", :string],
                      "vrfs" => ["NC_TFTP_VRFS", :json],
                      "servers" => ["NC_TFTP_SERVERS", :json],
                      "verification_roots" => ["NC_TFTP_ROOTS", :json],
                      "source_interfaces" => ["NC_TFTP_SOURCE_INTERFACES", :json],
                      "source_files" => ["NC_TFTP_SOURCE_FILES", :json],
                      "h3c_source_file" => ["NC_H3C_TFTP_SOURCE_FILE", :string],
                      "h3c_wireless_source_file" => ["NC_H3C_WIRELESS_TFTP_SOURCE_FILE", :string],
                      "huawei_source_file" => ["NC_HUAWEI_TFTP_SOURCE_FILE", :string] }
        }.freeze

        # 安全读取 YAML 配置并编码为 Settings 的内部键值。
        def self.load(path)
          raise ArgumentError, "config path must be a nonempty String" unless path.is_a?(String) && !path.empty?

          document = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
          parse(document)
        rescue Psych::Exception => error
          raise ArgumentError, "invalid YAML config (#{error.class})", cause: nil
        end

        # 文件读取与纯配置校验共用入口，初始化无需借临时文件验证。
        def self.parse(document)
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
        end

        # 按字段类型校验并编码单项配置。
        def self.encode(section, name, type, value)
          case type
          when :string
            raise ArgumentError, "#{section}.#{name} must be a nonempty String" unless value.is_a?(String) && !value.strip.empty?

            value
          when :integer, :optional_integer
            return nil if type == :optional_integer && value.nil?

            raise ArgumentError, "#{section}.#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

            value.to_s
          when :number
            unless value.is_a?(Numeric) && value.real? && value.finite? && value.positive? && value.to_f.finite?
              raise ArgumentError, "#{section}.#{name} must be a positive finite number"
            end

            value.to_s
          when :boolean
            raise ArgumentError, "#{section}.#{name} must be true or false" unless [true, false].include?(value)

            value.to_s
          when :list
            unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? && !item.include?(",") }
              raise ArgumentError, "#{section}.#{name} must be a list of strings without commas"
            end

            value.join(",")
          when :json, :json_array
            expected = type == :json_array || name == "device_rules" ? Array : Hash
            raise ArgumentError, "#{section}.#{name} must be a #{expected}" unless value.is_a?(expected)

            JSON.generate(value)
          end
        end

        private_class_method :encode
      end
    end
  end
end
