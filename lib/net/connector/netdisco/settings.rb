# frozen_string_literal: true

require "json"
require "uri"

module Net
  module Connector
    module Netdisco
      # 使用时从环境中读取配置，并提供明确的默认值。
      class Settings
        DEFAULT_BACKUP_DIRECTORY = "backups"
        DEFAULT_CONCURRENCY = 4
        MAX_CONCURRENCY = 50
        DEFAULT_PAGE_SIZE = 500

        # 加载 YAML 配置，并使环境变量覆盖文件配置。
        def self.from_file(path, env: ENV)
          new(env: ConfigFile.load(path).merge(env.to_h))
        end

        # 保存当前批次读取配置所用的环境映射。
        def initialize(env: ENV)
          @env = env
        end

        # 使用 Netdisco 地址和认证信息创建客户端。
        def client
          options = { url: required("NETDISCO_URL"), page_size: integer("NETDISCO_PAGE_SIZE", DEFAULT_PAGE_SIZE) }
          if present?(@env["NETDISCO_API_KEY"])
            options[:api_key] = @env["NETDISCO_API_KEY"]
          else
            options[:username] = required("NETDISCO_USERNAME")
            options[:password] = required("NETDISCO_PASSWORD")
          end
          Client.new(**options)
        end

        # 读取清单筛选和厂商映射规则。
        def rules
          Rules.new(include_hosts: list("NET_CONNECTOR_INCLUDE_HOSTS"),
                    exclude_hosts: list("NET_CONNECTOR_EXCLUDE_HOSTS"),
                    include_vendors: list("NET_CONNECTOR_INCLUDE_VENDORS"),
                    vendor_overrides: json("NET_CONNECTOR_VENDOR_OVERRIDES", {}),
                    host_overrides: json("NET_CONNECTOR_HOST_OVERRIDES", {}),
                    mappings: json("NET_CONNECTOR_DEVICE_RULES", []))
        end

        # 读取并展开本地备份目录。
        def backup_directory
          path = @env.fetch("NET_CONNECTOR_BACKUP_DIRECTORY", DEFAULT_BACKUP_DIRECTORY)
          raise ArgumentError, "NET_CONNECTOR_BACKUP_DIRECTORY must be nonempty" unless present?(path)

          File.expand_path(path)
        end

        # 读取并限制设备任务并发数。
        def concurrency
          count = integer("NET_CONNECTOR_CONCURRENCY", DEFAULT_CONCURRENCY)
          raise ArgumentError, "NET_CONNECTOR_CONCURRENCY must be at most #{MAX_CONCURRENCY}" if count > MAX_CONCURRENCY

          count
        end

        # 确定厂商采样数量：本地默认全量，TFTP 默认每厂商五台。
        def limit_per_vendor(tftp: false)
          return integer("NET_CONNECTOR_SAMPLE_PER_VENDOR", 5) if @env.key?("NET_CONNECTOR_SAMPLE_PER_VENDOR")

          5 if tftp
        end

        # 读取厂商的 TFTP 源文件配置，并提供华为启动配置默认路径。
        def tftp_source_files
          files = { huawei: @env.fetch("NET_CONNECTOR_HUAWEI_TFTP_SOURCE_FILE", "flash:/startup.cfg") }
          %i[h3c h3c_wireless].each do |vendor|
            key = "NET_CONNECTOR_#{vendor.to_s.upcase}_TFTP_SOURCE_FILE"
            files[vendor] = @env.fetch(key) if @env.key?(key)
          end
          files
        end

        # 读取各厂商 TFTP 出口 VRF 的名称映射。
        def tftp_vrfs
          raw = json("NET_CONNECTOR_TFTP_VRFS", {})
          raise ArgumentError, "NET_CONNECTOR_TFTP_VRFS must be a JSON object" unless raw.is_a?(Hash)

          raw.transform_keys(&:to_sym)
        end

        # 每台设备执行时读取凭据，使新批次可使用轮换后的环境变量。
        # 按厂商优先级读取设备账号与密码。
        def credentials_for(device)
          prefix = "NET_CONNECTOR_#{device.vendor.to_s.upcase}_"
          username = value(prefix + "USERNAME") || value("NET_CONNECTOR_DEVICE_USERNAME")
          return nil unless username

          {
            username: username,
            password: value(prefix + "PASSWORD") || value("NET_CONNECTOR_DEVICE_PASSWORD"),
            enable_password: value(prefix + "ENABLE_PASSWORD") || value("NET_CONNECTOR_ENABLE_PASSWORD"),
            protocol: (value(prefix + "PROTOCOL") || value("NET_CONNECTOR_PROTOCOL") || "ssh").to_sym,
            log_level: (value("NET_CONNECTOR_LOG_LEVEL") || "info").to_sym,
            known_hosts: value("NET_CONNECTOR_KNOWN_HOSTS"),
            host_key_policy: (value("NET_CONNECTOR_HOST_KEY_POLICY") || "strict").to_sym
          }
        end

        # 读取并展开设备日志目录。
        def log_directory
          path = value("NET_CONNECTOR_LOG_DIRECTORY")
          File.expand_path(path) if path
        end

        # 仅展示非敏感配置，不输出设备凭据或 API 密钥。
        # 生成不包含凭据的可展示配置。
        def public_config
          rules
          url = value("NETDISCO_URL")
          if url
            uri = URI.parse(url)
            unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
              raise ArgumentError, "NETDISCO_URL must be a base URL without credentials or query"
            end
          end
          {
            netdisco: { url: url, page_size: integer("NETDISCO_PAGE_SIZE", DEFAULT_PAGE_SIZE) },
            backup: { directory: backup_directory, concurrency: concurrency,
                      limit_per_vendor: limit_per_vendor },
            inventory: { include_hosts: list("NET_CONNECTOR_INCLUDE_HOSTS"),
                         exclude_hosts: list("NET_CONNECTOR_EXCLUDE_HOSTS"),
                         include_vendors: list("NET_CONNECTOR_INCLUDE_VENDORS"),
                         vendor_overrides: json("NET_CONNECTOR_VENDOR_OVERRIDES", {}),
                         host_overrides: json("NET_CONNECTOR_HOST_OVERRIDES", {}),
                         device_rules: json("NET_CONNECTOR_DEVICE_RULES", []) },
            ssh: { protocol: value("NET_CONNECTOR_PROTOCOL") || "ssh",
                   known_hosts: value("NET_CONNECTOR_KNOWN_HOSTS"),
                   host_key_policy: value("NET_CONNECTOR_HOST_KEY_POLICY") || "strict",
                   log_directory: log_directory,
                   log_level: value("NET_CONNECTOR_LOG_LEVEL") || "info" },
            tftp: { server: value("TFTP_HOST"), vrfs: tftp_vrfs.transform_keys(&:to_s) }
          }
        rescue URI::InvalidURIError
          raise ArgumentError, "NETDISCO_URL is invalid"
        end

        private

        # 解析指定环境变量中的 JSON 配置。
        def json(key, default)
          raw = value(key)
          raw ? JSON.parse(raw) : default
        rescue JSON::ParserError
          raise ArgumentError, "#{key} must be valid JSON"
        end

        # 解析逗号分隔的环境变量列表。
        def list(key) = @env.fetch(key, "").split(",").map(&:strip).reject(&:empty?)

        # 读取正整数配置并统一错误信息。
        def integer(key, default)
          raw = @env.fetch(key, default)
          value = Integer(raw.to_s, 10)
          raise ArgumentError, "#{key} must be a positive integer" unless value.positive?

          value
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{key} must be a positive integer"
        end

        # 读取非空字符串配置。
        def value(key)
          result = @env[key]
          result if present?(result)
        end

        # 读取必填环境变量。
        def required(key) = value(key) || (raise ArgumentError, "#{key} is required")

        # 判断环境变量是否为非空字符串。
        def present?(value) = value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
