# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../connector"
require_relative "../parallel/pool"
require_relative "inventory/http"
require_relative "inventory/postgres"
require_relative "inventory/cache"
require_relative "config"
require_relative "device/policy"
require_relative "tftp/policy"
require_relative "topology/options"
require_relative "rules"
require_relative "planner"

module Net
  module Connector
    module Netdisco
      # 活的凭据来源与不可变的批次策略分开保存；只有明确列出的非敏感字段进入快照。
      class Settings
        DEFAULT_BACKUP_DIRECTORY = "backups"
        DEFAULT_PARALLEL = Parallel::Pool::DEFAULT_PARALLEL
        MAX_PARALLEL = Parallel::Pool::MAX_PARALLEL
        # 这里只列可从环境读取的公开策略；凭据单独动态读取，其他内部键只供 YAML/CLI 使用。
        ENVIRONMENT_KEYS = %w[ND_URL ND_CACHE_TTL NC_PARALLEL].freeze
        DEFAULT_PAGE_SIZE = Inventory::DEFAULTS.fetch(:page_size)
        UNSET = Object.new.freeze
        private_constant :UNSET

        # 加载无凭据 YAML 作为默认策略，保留传入环境作为动态凭据来源。
        def self.from_file(path, env: ENV)
          new(env: env, defaults: Config.load(path))
        end

        # 只有 NC_CONFIG 显式指定时才读取文件，不隐式加载 .env。
        def self.from_env(env: ENV)
          path = env["NC_CONFIG"]
          path && !path.empty? ? from_file(path, env: env) : new(env: env)
        end

        # 分开保存默认策略、显式覆盖与凭据来源；fixed 实例只承载已复制的公开快照。
        def initialize(env: ENV, defaults: {}, overrides: {}, policy: nil, fixed: false, path_context: nil)
          @env, @defaults, @overrides = env, defaults, overrides
          @policy, @fixed = policy, fixed
          # 路径上下文只在内部固定策略之间传递，不属于用户配置或凭据来源。
          @path_context = (path_context || [Dir.pwd, Dir.home]).map { |path| path.dup.freeze }.freeze if fixed
        end

        # 调用入口补充运行目录等非敏感覆盖，凭据仍从同一来源读取。
        def with_overrides(values)
          if @fixed
            public_values = @env.merge(@overrides).merge(values).slice(*non_secret_keys)
                                .transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
            return self.class.new(env: public_values, fixed: true, path_context: @path_context).freeze
          end

          policy = @policy.with_overrides(values) if @policy
          self.class.new(env: @env, defaults: @defaults, overrides: @overrides.merge(values), policy: policy)
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

        # 按业务模式预检所有策略；离线导出仅验证目录，不读取清单或设备凭据。
        def validate!(mode:)
          unless %i[backup tftp topology inventory show_config export].include?(mode)
            raise ArgumentError, "unknown settings validation mode"
          end
          backup_directory
          topology_options
          return self if mode == :export

          inventory_options
          inventory_cache_options
          inventory_cache_mode
          rules
          parallel
          limit_per_vendor
          log_directory
          tftp_root
          connection_options
          database_options
          Net::Connector.vendors.each { |vendor| connection_options(vendor) }
          tftp_policy
          tftp_vrfs
          TftpTarget.new(host: tftp_server, path: "preflight.cfg") if tftp_server
          self
        end

        # 用固定策略创建清单来源，但每次读取最新身份凭据；显式认证覆盖默认认证来源。
        def inventory(policy: snapshot(mode: :inventory), credentials: nil)
          if credentials && (!credentials.is_a?(Hash) || credentials.keys.sort != %i[password username] ||
            !credentials.values.all? { |value| present?(value) })
            raise ArgumentError, "inventory credentials require nonempty username and password"
          end
          options = policy.inventory_options
          if policy.inventory_source == :postgres
            connection = Inventory::Postgres::CONNECTION_ENV.each_with_object(policy.database_options.dup) do |(key, name), values|
              item = secret_value(name)
              values[key] = item if item
            end
            connection.merge!(user: credentials[:username], password: credentials[:password]) if credentials
            inventory = Inventory::Postgres.new(connection_options: connection, **options) unless policy.inventory_cache_mode == :only
            identity = [:postgres, connection.except(:password), options.slice(:query, :query_params)]
            return cached_inventory(inventory, policy, identity)
          end
          raise ArgumentError, "ND_URL is required" unless options.fetch(:url)

          authentication = if credentials
                             credentials
                           elsif (token = secret_value("ND_API_KEY"))
                             { api_key: token }
                           else
                             password = policy.inventory_cache_mode == :only ? nil : required_secret("ND_PASSWORD")
                             { username: required_secret("ND_USERNAME"), password: password }
                           end
          inventory = Inventory::HTTP.new(**options, **authentication) unless policy.inventory_cache_mode == :only
          identity = [:http, Inventory::HTTP.validate_url!(options.fetch(:url)).normalize.to_s, authentication.except(:password)]
          cached_inventory(inventory, policy, identity)
        end

        # 清单来源来自 YAML/CLI，HTTP 与 PostgreSQL 共用后续计划和执行接口。
        def inventory_source
          source = value("ND_SOURCE") || "http"
          raise ArgumentError, "ND_SOURCE must be http or postgres" unless %w[http postgres].include?(source)

          source.to_sym
        end

        # 清单来源和 --show-config 共享预算校验；只验证所选来源的查询设置。
        def inventory_options
          defaults = inventory_source == :postgres ? Inventory::Postgres::DEFAULTS : Inventory::HTTP::DEFAULTS
          options = inventory_policy(defaults)
          inventory_source == :postgres ? postgres_options(options) : http_options(options)
        end

        # 默认三天，可由环境覆盖；缓存策略随批次固定，不缓存设备凭据或业务计划。
        def inventory_cache_options
          directory = raw("ND_CACHE_DIRECTORY", ".cache/net-connector/inventory")
          unless directory.is_a?(String) && !directory.empty? && !directory.include?("\0")
            raise ArgumentError, "netdisco.cache_directory must be a nonempty path without NUL"
          end
          { directory: absolute_path(directory), ttl: number("ND_CACHE_TTL", Inventory::Cache::DEFAULT_TTL),
            enabled: boolean("ND_CACHE_ENABLED", true) }.freeze
        end

        # 将有效配置转换为拓扑模式、并发、目录和描述格式策略。
        def topology_options
          directory = value("NC_TOPOLOGY_DIRECTORY")
          Topology::Options.new(mode: raw("NC_TOPOLOGY_MODE", "plan"), cache_mode: raw("NC_TOPOLOGY_CACHE_MODE", raw("ND_CACHE_MODE", "prefer")),
                              parallel: integer("NC_TOPOLOGY_PARALLEL", parallel), directory: directory && absolute_path(directory),
                              description_format: raw("NC_TOPOLOGY_DESCRIPTION_FORMAT", "To_%{neighbor}_%{port}"),
                              neighbor_name_prefixes: list("NC_TOPOLOGY_NEIGHBOR_NAME_PREFIXES"),
                              abbreviate_ports: boolean("NC_TOPOLOGY_ABBREVIATE", true), lowercase_ports: boolean("NC_TOPOLOGY_LOWERCASE", false),
                              limit: optional_integer("NC_TOPOLOGY_LIMIT"))
        end

        # 解析并限制清单缓存为优先缓存、仅缓存或强制刷新模式。
        def inventory_cache_mode
          mode = raw("ND_CACHE_MODE", "prefer")
          unless (mode.is_a?(String) || mode.is_a?(Symbol)) && %w[prefer only refresh].include?(mode.to_s)
            raise ArgumentError, "netdisco.cache_mode must be prefer, only or refresh"
          end
          mode.to_sym
        end

        # 将筛选和映射策略交给 Rules 校验，未识别设备由清单结果单独标记。
        def rules
          Rules.new(include_hosts: list("NC_INCLUDE_HOSTS"),
                    exclude_hosts: list("NC_EXCLUDE_HOSTS"),
                    include_vendors: list("NC_INCLUDE_VENDORS"),
                    exclude_vendors: list("NC_EXCLUDE_VENDORS"),
                    include_names: list("NC_INCLUDE_NAMES"), exclude_names: list("NC_EXCLUDE_NAMES"),
                    name_match: raw("NC_NAME_MATCH", "contains"),
                    include_models: list("NC_INCLUDE_MODELS"), exclude_models: list("NC_EXCLUDE_MODELS"),
                    model_match: raw("NC_MODEL_MATCH", "contains"),
                    vendor_overrides: json("NC_VENDOR_OVERRIDES", {}),
                    host_overrides: json("NC_HOST_OVERRIDES", {}),
                    mappings: json("NC_DEVICE_RULES", []))
        end

        # 将备份目录解析为绝对路径；这里只校验配置，不创建目录。
        def backup_directory
          path = raw("NC_BACKUP_DIRECTORY", DEFAULT_BACKUP_DIRECTORY)
          raise ArgumentError, "NC_BACKUP_DIRECTORY must be nonempty" unless present?(path)

          absolute_path(path)
        end

        # 与 Worker 共用并发上限，非法值在任务与目录创建前失败。
        def parallel
          count = integer("NC_PARALLEL", DEFAULT_PARALLEL)
          raise ArgumentError, "NC_PARALLEL must be at most #{MAX_PARALLEL}" if count > MAX_PARALLEL

          count
        end

        # 显式 nil 表示全量；tftp: true 且未设置时采用五台上限，示例入口另外选择全量。
        def limit_per_vendor(tftp: false)
          count = if configured?("NC_SAMPLE_PER_VENDOR")
                    integer("NC_SAMPLE_PER_VENDOR", 5) unless raw("NC_SAMPLE_PER_VENDOR").nil?
                  elsif tftp
                    5
                  end
          Planner.validate_limit!(count)
          count
        end

        # 华为批次默认上传 startup.cfg；H3C 省略源文件时由设备策略探测。
        def tftp_source_files
          files = { huawei: raw("NC_HUAWEI_TFTP_SOURCE_FILE", "flash:/startup.cfg") }
          %i[h3c h3c_wireless].each do |vendor|
            key = "NC_#{vendor.to_s.upcase}_TFTP_SOURCE_FILE"
            files[vendor] = raw(key) if configured?(key)
          end
          declared = json("NC_TFTP_SOURCE_FILES", {})
          raise ArgumentError, "tftp.source_files must be a mapping" unless declared.is_a?(Hash)

          files.merge(declared.transform_keys(&:to_sym))
        end

        # 解析各厂商与设备的 TFTP 源接口策略。
        def tftp_source_interfaces = json("NC_TFTP_SOURCE_INTERFACES", {})
        # 解析按精确设备地址覆盖的 TFTP 服务器映射。
        def tftp_servers = json("NC_TFTP_SERVERS", {})

        # 实时读取服务器归档密码，不将凭据纳入公开策略快照。
        def tftp_ssh_password = secret_value("NC_TFTP_SSH_PASSWORD")

        # 解析并校验各服务器对应的核验目录，避免跨服务器复用证据。
        def tftp_verification_roots
          mapping = json("NC_TFTP_ROOTS", {})
          raise ArgumentError, "tftp.verification_roots must be a mapping" unless mapping.is_a?(Hash)

          mapping.transform_values { |path| Tftp::Root.resolve(path) { |local| absolute_path(local) } }
        end

        # 组合服务器、源文件、源接口和 VRF，建立完整不可变传输策略。
        def tftp_policy
          Tftp::Policy.new(server: tftp_server, servers: tftp_servers, verification_root: tftp_root,
                           verification_roots: tftp_verification_roots, source_files: tftp_source_files,
                           source_interfaces: tftp_source_interfaces, vrfs: tftp_vrfs)
        end

        # 按厂商读取 VRF 映射，不能把不支持 VRF 的厂商静默忽略。
        def tftp_vrfs
          mapping = json("NC_TFTP_VRFS", {})
          raise ArgumentError, "NC_TFTP_VRFS must be a JSON object" unless mapping.is_a?(Hash)

          self.class.validate_vrfs!(mapping.transform_keys(&:to_sym))
        end

        # 解析参考配置中的厂商默认与精确设备覆盖；批次执行复用这个不可变选择器。
        def tftp_vrf_policy = self.class.vrf_policy(tftp_vrfs)

        # 按厂商能力验证 VRF 默认值及精确主机覆盖规则。
        def self.vrf_policy(vrfs)
          Device::Policy.new(vrfs, vendors: %i[cisco_nxos hillstone]) do |name|
            unless name.nil? || (name.is_a?(String) && name.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/))
              raise ArgumentError, "vrfs must contain safe VRF names or explicit null"
            end
          end
        end

        # 标量用于统一厂商策略，结构用于设备覆盖；规范化容器始终由本设置拥有。
        def self.validate_vrfs!(vrfs)
          policy = vrf_policy(vrfs)
          vrfs.to_h do |vendor, value|
            entry = policy.to_h.fetch(vendor.to_sym)
            [vendor.to_sym, value.is_a?(Hash) ? entry : entry[:default]]
          end.freeze
        end

        # 服务器地址只来自 YAML/CLI 的公开策略，不从 NC_TFTP_HOST 环境变量读取。
        def tftp_server = value("NC_TFTP_HOST")

        # 本机核验根目录属于策略快照，解析路径不证明文件已经上传。
        def tftp_root
          path = value("NC_TFTP_ROOT")
          Tftp::Root.resolve(path) { |local| absolute_path(local) } if path
        end

        # 端口、TLS 与连接超时进入固定策略；主机、数据库名和登录凭据仍从环境读取。
        def database_options
          return @policy.database_options if @policy

          options = {}
          %i[port connect_timeout].each do |name|
            key = "ND_DB_#{name.to_s.upcase}"
            next unless configured?(key)

            options[name] = integer(key, nil)
          end
          %i[sslmode sslrootcert].each do |name|
            item = value("ND_DB_#{name.to_s.upcase}")
            options[name] = item if item
          end
          options = Inventory::Postgres.connection_policy(**options)
          # libpq 的 system 是系统信任库标记；其他显式路径按字面解析，不展开波浪号。
          if @fixed && options[:sslrootcert] && options[:sslrootcert] != "system"
            options = options.merge(sslrootcert: File.absolute_path(options[:sslrootcert], @path_context.first).freeze).freeze
          end
          options
        end

        # 经 Configuration 复用连接校验；厂商协议覆盖通用协议，不包含设备凭据。
        def connection_options(vendor = nil)
          known_hosts = value("NC_KNOWN_HOSTS")
          configuration = Configuration.new(
            protocol: vendor_protocols[vendor.to_s] || value("NC_PROTOCOL") || "ssh",
            log_level: value("NC_LOG_LEVEL") || "info", known_hosts: known_hosts && absolute_path(known_hosts),
            host_key_policy: value("NC_HOST_KEY_POLICY") || "strict",
            max_script_output_bytes: optional_integer("NC_MAX_SCRIPT_OUTPUT_BYTES")
          )
          options = %i[protocol log_level known_hosts host_key_policy].to_h { |key| [key, configuration.public_send(key)] }
          options[:max_script_output_bytes] = configuration.max_script_output_bytes if configuration.max_script_output_bytes
          options.freeze
        end

        # 厂商协议必须使用已登记的厂商键和 ssh/telnet，不接受未知映射。
        def vendor_protocols
          values = json("NC_VENDOR_PROTOCOLS", {})
          unless values.is_a?(Hash) && values.all? { |vendor, protocol| Net::Connector.vendors.map(&:to_s).include?(vendor) && %w[ssh telnet].include?(protocol) }
            raise ArgumentError, "ssh.vendor_protocols must map supported vendors to ssh or telnet"
          end
          values
        end

        # 每台任务读取最新厂商凭据，缺失字段回退到通用凭据；无用户名时跳过设备。
        def device_credentials_for(device)
          prefix = "NC_#{device.vendor.to_s.upcase}_"
          username = secret_value(prefix + "USERNAME") || secret_value("NC_DEVICE_USERNAME")
          return nil unless username

          { username: username,
            password: secret_value(prefix + "PASSWORD") || secret_value("NC_DEVICE_PASSWORD"),
            enable_password: secret_value(prefix + "ENABLE_PASSWORD") || secret_value("NC_ENABLE_PASSWORD") }
        end

        # 会话日志目录属于公开策略；调用方和批次入口负责实际创建。
        def log_directory
          path = value("NC_LOG_DIRECTORY")
          absolute_path(path) if path
        end

        # 生成已验证的无凭据配置摘要，不展开原环境或 resolver。
        def public_config
          snapshot(mode: :show_config).config_hash
        end

        # 返回对象的安全摘要，不展开正文或认证凭据。
        def inspect = "#<#{self.class}>"

        protected

        # 只输出公开策略；数据库身份和设备凭据不得通过配置摘要进入报告。
        def config_hash
          {
            netdisco: inventory_options.merge(source: inventory_source, database: database_options, cache: inventory_cache_options, cache_mode: inventory_cache_mode),
            topology: topology_options.to_h,
            backup: { directory: backup_directory, parallel: parallel, limit_per_vendor: limit_per_vendor },
            inventory: { include_hosts: list("NC_INCLUDE_HOSTS"),
                         exclude_hosts: list("NC_EXCLUDE_HOSTS"),
                         include_vendors: list("NC_INCLUDE_VENDORS"),
                         exclude_vendors: list("NC_EXCLUDE_VENDORS"),
                         include_names: list("NC_INCLUDE_NAMES"), exclude_names: list("NC_EXCLUDE_NAMES"),
                         name_match: raw("NC_NAME_MATCH", "contains"),
                         include_models: list("NC_INCLUDE_MODELS"), exclude_models: list("NC_EXCLUDE_MODELS"),
                         model_match: raw("NC_MODEL_MATCH", "contains"),
                         vendor_overrides: json("NC_VENDOR_OVERRIDES", {}),
                         host_overrides: json("NC_HOST_OVERRIDES", {}),
                         device_rules: json("NC_DEVICE_RULES", []) },
            ssh: connection_options.transform_values { |item| item.is_a?(Symbol) ? item.to_s : item }.merge(
              log_directory: log_directory,
              vendor_protocols: vendor_protocols
            ),
            tftp: { server: tftp_server, verification_root: tftp_root, vrfs: tftp_vrfs.transform_keys(&:to_s), source_files: tftp_source_files,
                    source_interfaces: tftp_source_interfaces, servers: tftp_servers, verification_roots: tftp_verification_roots }
          }
        end

        # 优先读取固定策略或显式覆盖；内部键的名称不表示该键可由进程环境配置。
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

        # 固定策略及其覆盖共用快照的工作目录和主目录；活设置仍按调用时的环境解析。
        def absolute_path(path)
          return @policy.absolute_path(path) if @policy
          return File.expand_path(path) unless @fixed

          if path == "~" || path.start_with?("~/")
            home = @path_context.last
            raise ArgumentError, "non-absolute home" unless home.start_with?(File::SEPARATOR)

            path = home + path.delete_prefix("~")
          end
          File.expand_path(path, @path_context.first)
        end

        private

        # 身份指纹只用于隔离缓存；凭据、SQL 和参数均不写入缓存文件或摘要。
        def cached_inventory(inventory, policy, identity)
          cache = policy.inventory_cache_options
          if !cache.fetch(:enabled) && policy.inventory_cache_mode == :only
            raise Inventory::Error.new("validated inventory cache is unavailable", code: :cache_unavailable), cause: nil
          end
          return inventory unless cache.fetch(:enabled)

          options = policy.inventory_options
          cache_options = { **cache.except(:enabled), identity: Digest::SHA256.hexdigest(JSON.generate(identity)),
                            **options.slice(:max_inventory_bytes, :max_devices), lock_timeout: [5, options.fetch(:inventory_timeout)].min }
          if policy.inventory_cache_mode == :only
            Inventory::Cache.offline(**cache_options)
          else
            Inventory::Cache.new(inventory: inventory, cache_mode: policy.inventory_cache_mode, **cache_options)
          end
        end

        # 将共享清单配置逐项转换为合法预算与传输策略。
        def inventory_policy(defaults)
          defaults.to_h do |name, default|
            key = "ND_#{name.to_s.upcase}"
            parsed = case name
                     when :inventory_timeout then number(key, default)
                     when :allow_insecure_http then boolean(key, default)
                     else integer(key, default)
                     end
            [name, parsed]
          end
        end

        # 要求数据库清单具有查询文本，并校验绑定参数与公共预算。
        def postgres_options(options)
          query = value("ND_QUERY") || (raise ArgumentError, "ND_QUERY is required for postgres")
          Inventory::Postgres.options(query: query, query_params: json("ND_QUERY_PARAMS", []), **options)
        end

        # 拒绝 HTTP 来源混用 SQL 选项，校验端点和公共预算。
        def http_options(options)
          if value("ND_QUERY") || value("ND_QUERY_PARAMS")
            raise ArgumentError, "SQL query settings require ND_SOURCE=postgres"
          end
          options = Inventory::HTTP.options(**options)
          url = value("ND_URL")
          Inventory::HTTP.validate_url!(url, allow_insecure_http: options.fetch(:allow_insecure_http)) if url
          options.merge(url: url).freeze
        end

        # 列出公开配置允许映射的非敏感键，不将凭据混入快照。
        def non_secret_keys
          Config::FIELDS.values.flat_map { |section| section.values.map(&:first) }
        end

        # 旧前缀和已移除策略明确报错；错误只包含变量名，不泄露变量值。
        def validate_environment!
          legacy = @env.keys.find { |key| key.start_with?("NET_CONNECTOR_") }
          raise ArgumentError, "#{legacy} is unsupported; use NC_ credentials or YAML via NC_CONFIG" if legacy

          legacy = @env.keys.find { |key| key.start_with?("NETDISCO_", "TFTP_") }
          raise ArgumentError, "#{legacy} is unsupported; use ND_ credentials or YAML via NC_CONFIG" if legacy

          removed = non_secret_keys - ENVIRONMENT_KEYS
          removed.concat(%w[NC_PROGRESS NC_CONCURRENCY NC_TOPOLOGY_CONCURRENCY])
          removed += Net::Connector.vendors.map { |vendor| "NC_#{vendor.to_s.upcase}_PROTOCOL" }
          key = removed.find { |name| @env.key?(name) }
          raise ArgumentError, "#{key} is no longer an environment setting; use YAML via NC_CONFIG or CLI options" if key
        end

        # 判断配置键是否显式出现，保留缺失与显式空值的区别。
        def configured?(key) = !raw(key, UNSET).equal?(UNSET)

        # 解析可选 JSON 配置，缺失时沿用默认值，解析错误只显示配置键。
        def json(key, default)
          text = value(key)
          text ? JSON.parse(text) : default
        rescue JSON::ParserError
          raise ArgumentError, "#{key} must be valid JSON", cause: nil
        end

        # 显式空列表可清除筛选；空白或逗号空项不得被删掉后扩大选择范围。
        def list(key)
          text = raw(key)
          return [] if text.nil? || text == ""
          raise ArgumentError, "#{key} must be a String" unless text.is_a?(String)

          items = text.split(",", -1).map(&:strip)
          raise ArgumentError, "#{key} must not contain empty list entries" if items.any?(&:empty?)

          items
        end

        # 将配置转换为正整数，无效时只报告配置键和类型要求。
        def integer(key, default)
          result = Integer(raw(key, default).to_s, 10)
          raise ArgumentError unless result.positive?

          result
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{key} must be a positive integer", cause: nil
        end

        # 解析可省略的正整数参数，显式空值保持未设置。
        def optional_integer(key)
          integer(key, nil) unless raw(key).nil?
        end

        # 将配置转换为有限正数，拒绝无穷、非法或非正数。
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

        # 只接受布尔值或 true/false 文本，不按普通 Ruby 真值隐式转换。
        def boolean(key, default)
          result = raw(key, default)
          return true if result == true || result == "true"
          return false if result == false || result == "false"

          raise ArgumentError, "#{key} must be true or false"
        end

        # 读取可选字符串配置，将全空白文本视为未设置。
        def value(key)
          result = raw(key)
          raise ArgumentError, "#{key} must be a String" unless result.nil? || result.is_a?(String)

          result if present?(result)
        end

        # 凭据只从活的环境映射读取并复制，不允许 defaults/overrides 充当秘密来源。
        def secret_value(key)
          result = @env[key]
          raise ArgumentError, "#{key} must be a String" unless result.nil? || result.is_a?(String)

          result.dup.freeze if present?(result)
        end

        # 只从实时凭据来源读取必需秘密，缺失时提示变量名而不显示值。
        def required_secret(key) = secret_value(key) || (raise ArgumentError, "#{key} is required")

        # 判断输入是否为包含非空白内容的字符串。
        def present?(value) = value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
