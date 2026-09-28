# frozen_string_literal: true

require "json"

module Net
  module Connector
    module Netdisco
      # 活的凭据来源与不可变的批次策略分开保存；只有明确列出的非敏感字段进入快照。
      class Settings
        DEFAULT_BACKUP_DIRECTORY = "backups"
        DEFAULT_CONCURRENCY = 4
        MAX_CONCURRENCY = 50
        ENVIRONMENT_KEYS = %w[NETDISCO_URL NC_BACKUP_DIRECTORY NC_CONCURRENCY NC_SAMPLE_PER_VENDOR
                              NC_PROTOCOL NC_KNOWN_HOSTS NC_HOST_KEY_POLICY NC_LOG_DIRECTORY NC_LOG_LEVEL TFTP_HOST].freeze
        DEFAULT_PAGE_SIZE = Client::DEFAULTS.fetch(:page_size)
        UNSET = Object.new.freeze
        private_constant :UNSET

        def self.from_file(path, env: ENV)
          new(env: env, defaults: ConfigFile.load(path))
        end

        def self.from_env(env: ENV)
          path = env["NC_CONFIG"]
          path && !path.empty? ? from_file(path, env: env) : new(env: env)
        end

        def initialize(env: ENV, defaults: {}, overrides: {}, policy: nil, fixed: false)
          @env, @defaults, @overrides = env, defaults, overrides
          @policy, @fixed = policy, fixed
        end

        # 调用入口补充运行目录等非敏感覆盖，凭据仍从同一来源读取。
        def with_overrides(values)
          self.class.new(env: @env, defaults: @defaults, overrides: @overrides.merge(values))
        end

        # 快照自身不保留 ENV、凭据 resolver 或原 Settings 的引用，不能携带秘密进入摘要。
        def snapshot(mode: :backup)
          return @policy.validate!(mode: mode) if @policy
          return validate!(mode: mode) if @fixed

          validate_environment! unless mode == :export

          keys = mode == :export ? ["NC_BACKUP_DIRECTORY"] : non_secret_keys
          values = keys.each_with_object({}) do |key, result|
            item = raw(key, UNSET)
            result[key.freeze] = item.is_a?(String) ? item.dup.freeze : item unless item.equal?(UNSET)
          end
          self.class.new(env: values.freeze, fixed: true).validate!(mode: mode).freeze
        end

        # CLI 的一次预览/执行使用同一策略；凭据仍指向原环境映射，允许逐设备轮换。
        def for_run(mode: :backup)
          self.class.new(env: @env, defaults: @defaults, overrides: @overrides, policy: snapshot(mode: mode))
        end

        def validate!(mode:)
          unless %i[backup tftp inventory show_config export].include?(mode)
            raise ArgumentError, "unknown settings validation mode"
          end
          backup_directory
          return self if mode == :export

          client_options
          rules
          concurrency
          limit_per_vendor
          log_directory
          connection_options
          Net::Connector.vendors.each { |vendor| connection_options(vendor) }
          tftp_source_files.each_value { |source| TftpTarget.validate_source_file!(source) }
          tftp_vrfs
          TftpTarget.new(host: tftp_server, path: "preflight.cfg") if tftp_server
          self
        end

        def client(policy: snapshot(mode: :inventory), credentials: nil)
          if credentials && (!credentials.is_a?(Hash) || credentials.keys.sort != %i[password username] ||
            !credentials.values.all? { |value| present?(value) })
            raise ArgumentError, "inventory credentials require nonempty username and password"
          end
          options = policy.client_options
          if policy.inventory_source == :postgres
            connection = DatabaseClient::CONNECTION_ENV.each_with_object({}) do |(key, name), values|
              item = secret_value(name)
              values[key] = item if item
            end
            connection.merge!(user: credentials[:username], password: credentials[:password]) if credentials
            return DatabaseClient.new(connection_options: connection, **options)
          end
          raise ArgumentError, "NETDISCO_URL is required" unless options.fetch(:url)

          authentication = if credentials
                             credentials
                           elsif (token = secret_value("NETDISCO_API_KEY"))
                             { api_key: token }
                           else
                             { username: required_secret("NETDISCO_USERNAME"), password: required_secret("NETDISCO_PASSWORD") }
                           end
          Client.new(**options, **authentication)
        end

        def inventory_source
          source = value("NETDISCO_SOURCE") || "http"
          raise ArgumentError, "NETDISCO_SOURCE must be http or postgres" unless %w[http postgres].include?(source)

          source.to_sym
        end

        # 原生客户端和 --show-config 共享预算校验；只验证所选来源的查询设置。
        def client_options
          defaults = inventory_source == :postgres ? DatabaseClient::DEFAULTS : Client::DEFAULTS
          options = client_budget_options(defaults)
          inventory_source == :postgres ? postgres_options(options) : http_options(options)
        end

        def rules
          Rules.new(include_hosts: list("NC_INCLUDE_HOSTS"),
                    exclude_hosts: list("NC_EXCLUDE_HOSTS"),
                    include_vendors: list("NC_INCLUDE_VENDORS"),
                    vendor_overrides: json("NC_VENDOR_OVERRIDES", {}),
                    host_overrides: json("NC_HOST_OVERRIDES", {}),
                    mappings: json("NC_DEVICE_RULES", []))
        end

        def backup_directory
          path = raw("NC_BACKUP_DIRECTORY", DEFAULT_BACKUP_DIRECTORY)
          raise ArgumentError, "NC_BACKUP_DIRECTORY must be nonempty" unless present?(path)

          File.expand_path(path)
        end

        def concurrency
          count = integer("NC_CONCURRENCY", DEFAULT_CONCURRENCY)
          raise ArgumentError, "NC_CONCURRENCY must be at most #{MAX_CONCURRENCY}" if count > MAX_CONCURRENCY

          count
        end

        def limit_per_vendor(tftp: false)
          count = if configured?("NC_SAMPLE_PER_VENDOR")
                    integer("NC_SAMPLE_PER_VENDOR", 5) unless raw("NC_SAMPLE_PER_VENDOR").nil?
                  elsif tftp
                    5
                  end
          Planner.validate_limit!(count)
          count
        end

        def tftp_source_files
          files = { huawei: raw("NC_HUAWEI_TFTP_SOURCE_FILE", "flash:/startup.cfg") }
          %i[h3c h3c_wireless].each do |vendor|
            key = "NC_#{vendor.to_s.upcase}_TFTP_SOURCE_FILE"
            files[vendor] = raw(key) if configured?(key)
          end
          files
        end

        def tftp_vrfs
          mapping = json("NC_TFTP_VRFS", {})
          raise ArgumentError, "NC_TFTP_VRFS must be a JSON object" unless mapping.is_a?(Hash)

          self.class.validate_vrfs!(mapping.transform_keys(&:to_sym))
        end

        def self.validate_vrfs!(vrfs)
          unless vrfs.is_a?(Hash) && vrfs.all? { |vendor, name|
            %i[cisco_nxos hillstone].include?(vendor) && name.is_a?(String) &&
              name.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/)
          }
            raise ArgumentError, "vrfs must map supported vendor names to safe VRF names"
          end
          vrfs
        end

        def tftp_server = value("TFTP_HOST")

        def connection_options(vendor = nil)
          configuration = Configuration.new(
            protocol: vendor_protocols[vendor.to_s] || value("NC_PROTOCOL") || "ssh",
            log_level: value("NC_LOG_LEVEL") || "info", known_hosts: value("NC_KNOWN_HOSTS"),
            host_key_policy: value("NC_HOST_KEY_POLICY") || "strict",
            max_script_output_bytes: optional_integer("NC_MAX_SCRIPT_OUTPUT_BYTES")
          )
          options = %i[protocol log_level known_hosts host_key_policy].to_h { |key| [key, configuration.public_send(key)] }
          options[:max_script_output_bytes] = configuration.max_script_output_bytes if configuration.max_script_output_bytes
          options.freeze
        end

        def vendor_protocols
          values = json("NC_VENDOR_PROTOCOLS", {})
          unless values.is_a?(Hash) && values.all? { |vendor, protocol| Net::Connector.vendors.map(&:to_s).include?(vendor) && %w[ssh telnet].include?(protocol) }
            raise ArgumentError, "ssh.vendor_protocols must map supported vendors to ssh or telnet"
          end
          values
        end

        def device_credentials_for(device)
          prefix = "NC_#{device.vendor.to_s.upcase}_"
          username = secret_value(prefix + "USERNAME") || secret_value("NC_DEVICE_USERNAME")
          return nil unless username

          { username: username,
            password: secret_value(prefix + "PASSWORD") || secret_value("NC_DEVICE_PASSWORD"),
            enable_password: secret_value(prefix + "ENABLE_PASSWORD") || secret_value("NC_ENABLE_PASSWORD") }
        end

        def log_directory
          path = value("NC_LOG_DIRECTORY")
          File.expand_path(path) if path
        end

        def public_config
          snapshot(mode: :show_config).config_hash
        end

        def inspect = "#<#{self.class}>"

        protected

        def config_hash
          {
            netdisco: client_options.merge(source: inventory_source),
            backup: { directory: backup_directory, concurrency: concurrency, limit_per_vendor: limit_per_vendor },
            inventory: { include_hosts: list("NC_INCLUDE_HOSTS"),
                         exclude_hosts: list("NC_EXCLUDE_HOSTS"),
                         include_vendors: list("NC_INCLUDE_VENDORS"),
                         vendor_overrides: json("NC_VENDOR_OVERRIDES", {}),
                         host_overrides: json("NC_HOST_OVERRIDES", {}),
                         device_rules: json("NC_DEVICE_RULES", []) },
            ssh: connection_options.transform_values { |item| item.is_a?(Symbol) ? item.to_s : item }.merge(
              log_directory: log_directory,
              vendor_protocols: vendor_protocols
            ),
            tftp: { server: tftp_server, vrfs: tftp_vrfs.transform_keys(&:to_s), source_files: tftp_source_files }
          }
        end

        def raw(key, default = nil)
          return @policy.raw(key, default) if @policy
          return @overrides.fetch(key) if @overrides.key?(key)
          if @env.key?(key)
            unless @fixed || ENVIRONMENT_KEYS.include?(key)
              raise ArgumentError, "#{key} is no longer an environment setting; use YAML via NC_CONFIG or CLI options"
            end
            return @env.fetch(key)
          end

          @defaults.fetch(key, default)
        end

        private

        def client_budget_options(defaults)
          defaults.to_h do |name, default|
            key = "NETDISCO_#{name.to_s.upcase}"
            parsed = case name
                     when :inventory_timeout then number(key, default)
                     when :allow_insecure_http then boolean(key, default)
                     else integer(key, default)
                     end
            [name, parsed]
          end
        end

        def postgres_options(options)
          query = value("NETDISCO_QUERY") || (raise ArgumentError, "NETDISCO_QUERY is required for postgres")
          DatabaseClient.options(query: query, query_params: json("NETDISCO_QUERY_PARAMS", []), **options)
        end

        def http_options(options)
          if value("NETDISCO_QUERY") || value("NETDISCO_QUERY_PARAMS")
            raise ArgumentError, "SQL query settings require NETDISCO_SOURCE=postgres"
          end
          options = Client.options(**options)
          url = value("NETDISCO_URL")
          Client.validate_url!(url, allow_insecure_http: options.fetch(:allow_insecure_http)) if url
          options.merge(url: url).freeze
        end

        def non_secret_keys
          ConfigFile::FIELDS.values.flat_map { |section| section.values.map(&:first) }
        end

        def validate_environment!
          legacy = @env.keys.find { |key| key.start_with?("NET_CONNECTOR_") }
          raise ArgumentError, "#{legacy} has been renamed to #{legacy.sub("NET_CONNECTOR_", "NC_")}" if legacy

          removed = non_secret_keys - ENVIRONMENT_KEYS
          removed += Net::Connector.vendors.map { |vendor| "NC_#{vendor.to_s.upcase}_PROTOCOL" }
          key = removed.find { |name| @env.key?(name) }
          raise ArgumentError, "#{key} is no longer an environment setting; use YAML via NC_CONFIG or CLI options" if key
        end

        def configured?(key) = !raw(key, UNSET).equal?(UNSET)

        def json(key, default)
          text = value(key)
          text ? JSON.parse(text) : default
        rescue JSON::ParserError
          raise ArgumentError, "#{key} must be valid JSON", cause: nil
        end

        def list(key) = (value(key) || "").split(",").map(&:strip).reject(&:empty?)

        def integer(key, default)
          result = Integer(raw(key, default).to_s, 10)
          raise ArgumentError unless result.positive?

          result
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{key} must be a positive integer", cause: nil
        end

        def optional_integer(key)
          integer(key, nil) unless raw(key).nil?
        end

        def number(key, default)
          input = raw(key, default)
          result = input.is_a?(String) ? Float(input) : input
          unless result.is_a?(Numeric) && result.real? && result.finite? && result.positive? && result.to_f.finite?
            raise ArgumentError
          end
          result
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{key} must be a positive finite number", cause: nil
        end

        def boolean(key, default)
          result = raw(key, default)
          return true if result == true || result == "true"
          return false if result == false || result == "false"

          raise ArgumentError, "#{key} must be true or false"
        end

        def value(key)
          result = raw(key)
          raise ArgumentError, "#{key} must be a String" unless result.nil? || result.is_a?(String)

          result if present?(result)
        end

        def secret_value(key)
          result = @env[key]
          raise ArgumentError, "#{key} must be a String" unless result.nil? || result.is_a?(String)

          result.dup.freeze if present?(result)
        end

        def required_secret(key) = secret_value(key) || (raise ArgumentError, "#{key} is required")

        def present?(value) = value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
