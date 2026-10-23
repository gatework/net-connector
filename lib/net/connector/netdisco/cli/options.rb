# frozen_string_literal: true

require "optparse"
require "ctx_cli/options"
require "ctx_cli/terminal"
require_relative "../settings"
require_relative "../planner"
require_relative "../config"
require_relative "../../config"
require_relative "help"
require_relative "../../inventory/filters"

module Net
  module Connector
    module Netdisco
      class CLI
        # 可注入参数与输入输出的备份选项，不退出宿主进程。
        class Options
          # 复制参数数组，返回选项或帮助标记；非法输入抛错，不退出宿主进程。
          def self.parse(argv: ARGV, input: $stdin, output: $stdout, error: $stderr, program: $PROGRAM_NAME, mode: :backup, &additional)
            values = { environment: {}, json: false, verbose: false, stdin_credentials: false }
            parser = parser_for(values, output: output, program: program, mode: mode, &additional)
            remaining = parser.parse!(argv.dup)
            return values if values[:help]
            raise OptionParser::InvalidArgument unless remaining.empty?
            credentials = values[:environment].keys.any? { |key| key.match?(/USERNAME|PASSWORD/) }
            if values[:stdin_credentials] && (credentials || values[:ask_password] || values[:ask_netdisco_password])
              raise ArgumentError, "--stdin-credentials cannot be combined with command-line credentials or password prompts"
            end
            read_password(values, :ask_password, "NC_DEVICE_PASSWORD", "Device password", input: input, output: error)
            read_password(values, :ask_netdisco_password, "ND_PASSWORD", "Netdisco password", input: input, output: error)

            values
          rescue OptionParser::ParseError
            limits = mode == :topology ? "Concurrency must be 1 to 500; device limit must be a positive integer" : "Concurrency must be 1 to 500; sample size must be 1 to 5"
            raise ArgumentError, "Invalid arguments: #{limits}; use --help for options", cause: nil
          end

          # 组装当前模式的选项、帮助和扩展参数，解析器自身不执行设备任务。
          def self.parser_for(values, output:, program:, mode:, &additional)
            raise ArgumentError, "unknown CLI mode" unless %i[backup tftp topology].include?(mode)

            OptionParser.new do |opts|
              default = mode == :topology ? "read-only planning by default" : "use the configuration by default"
              opts.banner = "Usage: ruby #{File.basename(program)} [options] (#{default})\nCommand-line options take precedence; unspecified values use configuration and defaults. Without filters, all ready devices are selected."
              add_settings(opts, values, mode: mode)
              add_execution(opts, values, mode: mode)
              add_terminal_options(opts, values)
              if mode == :topology
                add_topology(opts, values)
              else
                opts.on("--plan", "--inventory-only", "Preview filtered inventory without connecting to devices") { values[:inventory_only] = true }
              end
              additional&.call(opts, values)
              opts.on("--examples", "Show common command examples without executing tasks") do
                output.puts Help.examples(program: program, mode: mode)
                values[:help] = true
              end
              opts.on("-h", "--help", "Show common options") do
                output.puts Help.common(opts, mode: mode)
                values[:help] = true
              end
              opts.on("--help-all", "Show all options, including credentials, SSH and automation") { output.puts opts; values[:help] = true }
            end
          end

          # 登记进度、JSON、密码输入及配置问答等终端选项。
          def self.add_terminal_options(opts, values)
            opts.on("--ask-password", "Prompt for the device password without echoing input") { values[:ask_password] = true }
            opts.on("--ask-netdisco-password", "Prompt for the Netdisco password without echoing input") { values[:ask_netdisco_password] = true }
            CtxCli::Options.output(opts, values, quiet: :no_progress)
            opts.on("--stdin-credentials", "Read credentials from stdin and wait for RUN") { values[:stdin_credentials] = true }
            CtxCli::Options.initialization(opts, values)
          end

          # 登记互斥的拓扑执行模式和格式化参数，应用模式必须显式选择。
          def self.add_topology(opts, values)
            { discover: "Discover neighbors and check descriptions", plan: "Generate a configuration plan", apply: "Apply corrections, read back and save" }.each do |mode, description|
              opts.on("--#{mode}", description) do
                raise ArgumentError, "--discover, --plan and --apply are mutually exclusive" if values[:topology_mode]

                values[:topology_mode] = mode
                values[:apply] = true if mode == :apply
              end
            end
            opts.on("--inventory-only", "Read and filter inventory without connecting to devices") { values[:inventory_only] = true }
            opts.on("--limit N", Integer, "Select at most N discoverable devices") do |value|
              raise OptionParser::InvalidArgument unless value.positive?

              values[:topology_limit] = value
            end
            opts.on("--description-format TEXT", "Template supports only %{neighbor} and %{port}") { |value| values[:environment]["NC_TOPOLOGY_DESCRIPTION_FORMAT"] = value }
            opts.on("--full-port-names", "Keep full neighbor port names") { values[:environment]["NC_TOPOLOGY_ABBREVIATE"] = "false" }
            opts.on("--lowercase-ports", "Convert neighbor port names to lowercase") { values[:environment]["NC_TOPOLOGY_LOWERCASE"] = "true" }
          end

          # 正式 CLI 与批次示例共用并发、抽样、核验和成功策略选项。
          def self.add_execution(opts, values, mode: nil)
            opts.on("--refresh-inventory", "Force inventory refresh; fall back to verified history on remote failure") { values[:force_refresh] = true }
            opts.on("--cache-only", "Use only verified cached inventory without querying the remote source") { values[:environment]["ND_CACHE_MODE"] = "only" }
            opts.on("--cache-mode MODE", %w[prefer only refresh], "Inventory cache: prefer / only / refresh") do |value|
              values[:environment]["ND_CACHE_MODE"] = value
            end
            opts.on("-p", "--parallel N", Integer, "Concurrent devices, 1 to 500") do |count|
              raise OptionParser::InvalidArgument unless (1..Settings::MAX_PARALLEL).cover?(count)

              values[:environment]["NC_PARALLEL"] = count.to_s
            end
            return if mode == :topology

            opts.on("--sample N", "--limit-per-vendor N", Integer, "Sample 1 to 5 devices per vendor") do |count|
              Planner.validate_limit!(count)
              values[:limit] = count
            end
            opts.on("--tftp-root DIR", "Local directory containing TFTP server files") { |path| values[:tftp_root] = path }
            opts.on("--all", "Select all ready devices") { values[:all] = true }
            opts.on("--success-policy POLICY", %w[strict selected verified], "Success policy: strict / selected / verified (TFTP file verification)") do |policy|
              values[:success_policy] = policy.to_sym
            end
          end

          PATH_FIELDS = %w[netdisco.cache_directory netdisco.db_sslrootcert ssh.known_hosts ssh.log_directory backup.directory
                           topology.directory tftp.verification_root tftp.verification_roots.*].freeze
          ENV_PATH_KEYS = %w[ND_CACHE_DIRECTORY ND_DB_SSLROOTCERT NC_KNOWN_HOSTS NC_LOG_DIRECTORY NC_BACKUP_DIRECTORY
                             NC_TOPOLOGY_DIRECTORY NC_TFTP_ROOT].freeze

          PATH_LITERALS = { "netdisco.db_sslrootcert" => ["system"].freeze,
                            "ND_DB_SSLROOTCERT" => ["system"].freeze }.freeze

          # 构造宿主配置发现器；帮助解析不调用本方法，不读取用户文件。
          def self.configuration(options, env: ENV, mode: :backup, **context)
            Net::Connector::Config.new(name: mode == :topology ? "topology" : "backup", env: env,
                                       config: options.fetch(:environment)["NC_CONFIG"], env_file: options[:env_file],
                                       config_env: "NC_CONFIG", path_fields: PATH_FIELDS, env_path_keys: ENV_PATH_KEYS, path_literals: PATH_LITERALS, **context)
          end

          # CLI > 原进程环境 > YAML > .env；公开环境字段转为内部策略，凭据仍独立读取。
          def self.settings(options, env: ENV, mode: :backup, configuration: nil, defaults: {})
            raise ArgumentError, "--all cannot be combined with sampling" if options[:all] && options[:limit]
            if options[:host] && options.fetch(:environment).key?("NC_INCLUDE_HOSTS")
              raise ArgumentError, "--host cannot be combined with --hosts"
            end

            files = (configuration || self.configuration(options, env: env, mode: mode)).load
            yaml = Config.parse(files.data)
            public_keys = Config::FIELDS.values.flat_map { |fields| fields.values.map(&:first) }
            overrides = options.fetch(:environment).slice(*public_keys)
            { source: "ND_SOURCE", query: "ND_QUERY", query_params: "ND_QUERY_PARAMS",
              max_script_output_bytes: "NC_MAX_SCRIPT_OUTPUT_BYTES", host: "NC_INCLUDE_HOSTS",
              limit: "NC_SAMPLE_PER_VENDOR", tftp_root: "NC_TFTP_ROOT" }.each do |option, key|
              overrides[key] = options[option].to_s if options.key?(option)
            end
            overrides["NC_SAMPLE_PER_VENDOR"] = nil if options[:all]
            process = public_environment(files.process_environment)
            if mode == :topology
              process["NC_TOPOLOGY_PARALLEL"] ||= process["NC_PARALLEL"] if process.key?("NC_PARALLEL")
              overrides["NC_TOPOLOGY_PARALLEL"] = overrides["NC_PARALLEL"] if overrides.key?("NC_PARALLEL")
            end
            overrides = process.except(*overrides.keys).merge(overrides)
            file_values = files.file_environment.except(*yaml.keys, *overrides.keys)
            environment = environment(options, env: files.environment).reject { |key, _| public_keys.include?(key) }
            Settings.new(env: environment, defaults: defaults.merge(public_environment(file_values)).merge(yaml), overrides: overrides)
          end

          # 环境文本已是 Settings 的编码格式；由当前执行模式验证实际使用的字段。
          def self.public_environment(environment)
            keys = Config::FIELDS.values.flat_map { |fields| fields.values.map(&:first) }
            environment.slice(*keys)
          end

          # 配置来源只包含路径及来源标记；不展开凭据环境或文件正文。
          def self.sources(configuration, options)
            configuration.sources.merge("overrides" => {
              "process_environment" => configuration.process_environment.keys & Config::FIELDS.values.flat_map { |fields| fields.values.map(&:first) },
              "command_line" => options.fetch(:environment).keys.grep_v(/PASSWORD|USERNAME|API_KEY/)
            })
          end

          # 共用配置与凭据参数登记；具体入口决定后续预览、执行或导出。
          def self.add_settings(opts, values, mode: nil)
            add_filters(opts, values)
            {
              "--username USER" => ["NC_DEVICE_USERNAME", "Device login username"],
              "--password PASSWORD" => ["NC_DEVICE_PASSWORD", "Device login password (or use --ask-password)"],
              "--enable-password PASSWORD" => ["NC_ENABLE_PASSWORD", "Device privilege password"],
              "--netdisco-url URL" => ["ND_URL", "Netdisco URL"],
              "--netdisco-username USER" => ["ND_USERNAME", "Netdisco username"],
              "--netdisco-password PASSWORD" => ["ND_PASSWORD", "Netdisco password"],
              "--directory DIR" => ["NC_BACKUP_DIRECTORY", "#{mode == :topology ? "Topology report" : "Backup"} directory, relative to the startup directory"],
              "--config FILE" => ["NC_CONFIG", "YAML configuration, relative to the startup directory"]
            }.each do |flag, (key, description)|
              opts.on(flag, description) do |value|
                raise OptionParser::InvalidArgument if value.empty?

                values[:environment][key] = value
              end
            end
            opts.on("--env-file FILE", "Environment file loaded last, relative to the startup directory") { |path| values[:env_file] = path }
            opts.on("--show-config", "Show effective nonsensitive settings and configuration sources") { values[:show_config] = true }
            opts.on("--host-key-policy POLICY", %w[strict accept_new replace], "Host key policy: strict / accept_new / replace (automatically replace changed keys)") do |policy|
              values[:environment]["NC_HOST_KEY_POLICY"] = policy
            end
            opts.on("--known-hosts FILE", "File for persistent host keys") do |path|
              values[:environment]["NC_KNOWN_HOSTS"] = path
            end
          end

          # 同类 CLI 筛选替换 YAML；重复参数在本次调用内合并，绝不把范围展开为地址列表。
          def self.add_filters(opts, values)
            Net::Connector::Inventory::Filters.add_options(opts, single_host: false) do |key, value|
              field = Net::Connector::Inventory::Filters::LISTS.fetch(key, key).to_s
              environment_key = "NC_#{field.upcase}"
              if value.is_a?(Array)
                previous = values[:environment][environment_key]&.split(",") || []
                values[:environment][environment_key] = (previous + value).uniq.join(",")
              else
                values[:environment][environment_key] = value
              end
            end
            opts.on("--host IP", "Select one device; may be repeated") do |value|
              raise OptionParser::InvalidArgument if value.empty? || value.match?(/[\/,]/)

              begin
                address = IPAddr.new(value).to_s
              rescue IPAddr::Error
                raise OptionParser::InvalidArgument
              end
              values[:host] = [*values[:host]&.split(","), address].uniq.join(",")
            end
          end
          private_class_method :add_filters

          # 复制原环境并合并显式凭据，清除被通用凭据覆盖的厂商值及旧 API key。
          def self.environment(options, env: ENV)
            result = env.to_h.dup
            overrides = options.fetch(:environment)
            # 显式设备参数覆盖对应厂商默认值；未指定的字段继续按原凭据规则解析。
            { "NC_DEVICE_USERNAME" => "USERNAME", "NC_DEVICE_PASSWORD" => "PASSWORD",
              "NC_ENABLE_PASSWORD" => "ENABLE_PASSWORD" }.each do |key, suffix|
              next unless overrides.key?(key)

              result.delete_if do |name, _|
                name.start_with?("NC_") && name.end_with?("_#{suffix}") &&
                  (suffix != "PASSWORD" || !name.end_with?("_ENABLE_PASSWORD"))
              end
            end
            if overrides.key?("ND_USERNAME") || overrides.key?("ND_PASSWORD")
              result.delete("ND_API_KEY")
            end
            result.merge(overrides)
          end

          # 隐藏输入只用于交互终端；与显式密码互斥，不输出或记录密码内容。
          def self.read_password(values, flag, key, label, input:, output:)
            return unless values[flag]

            raise ArgumentError, "Password prompts cannot be combined with explicit passwords" if values[:environment].key?(key)
            values[:environment][key] = CtxCli::Terminal.new(input: input, out: output).password(label: label)
          end
          private_class_method :read_password, :parser_for
        end
      end
    end
  end
end
