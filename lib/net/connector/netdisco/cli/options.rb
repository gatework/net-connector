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
              raise ArgumentError, "--stdin-credentials 不能与命令行凭据或密码提示同时使用"
            end
            read_password(values, :ask_password, "NC_DEVICE_PASSWORD", "设备密码", input: input, output: error)
            read_password(values, :ask_netdisco_password, "ND_PASSWORD", "Netdisco 密码", input: input, output: error)

            values
          rescue OptionParser::ParseError
            limits = mode == :topology ? "并发数须为 1 至 500，设备上限须为正整数" : "并发数须为 1 至 500，抽样须为 1 至 5"
            raise ArgumentError, "参数无效：#{limits}；使用 --help 查看参数", cause: nil
          end

          # 组装当前模式的选项、帮助和扩展参数，解析器自身不执行设备任务。
          def self.parser_for(values, output:, program:, mode:, &additional)
            raise ArgumentError, "unknown CLI mode" unless %i[backup tftp topology].include?(mode)

            OptionParser.new do |opts|
              default = mode == :topology ? "默认只读规划" : "默认沿用配置"
              opts.banner = "用法：ruby #{File.basename(program)} [选项]（#{default}）\n命令行参数优先；未指定的项沿用配置及默认值。无筛选时选择全部就绪设备。"
              add_settings(opts, values, mode: mode)
              add_execution(opts, values, mode: mode)
              add_terminal_options(opts, values)
              if mode == :topology
                add_topology(opts, values)
              else
                opts.on("--plan", "--inventory-only", "预览过滤后的清单，不连接设备") { values[:inventory_only] = true }
              end
              additional&.call(opts, values)
              opts.on("--examples", "查看常用命令范例，不执行任务") do
                output.puts Help.examples(program: program, mode: mode)
                values[:help] = true
              end
              opts.on("-h", "--help", "显示常用选项") do
                output.puts Help.common(opts, mode: mode)
                values[:help] = true
              end
              opts.on("--help-all", "显示完整选项（凭据、SSH、自动化等）") { output.puts opts; values[:help] = true }
            end
          end

          # 登记进度、JSON、密码输入及配置问答等终端选项。
          def self.add_terminal_options(opts, values)
            opts.on("--ask-password", "隐藏输入设备密码") { values[:ask_password] = true }
            opts.on("--ask-netdisco-password", "隐藏输入 Netdisco 密码") { values[:ask_netdisco_password] = true }
            CtxCli::Options.output(opts, values, quiet: :no_progress)
            opts.on("--stdin-credentials", "从标准输入读取凭据并等待 RUN") { values[:stdin_credentials] = true }
            CtxCli::Options.initialization(opts, values)
          end

          # 登记互斥的拓扑执行模式和格式化参数，应用模式必须显式选择。
          def self.add_topology(opts, values)
            { discover: "发现邻居并检查描述", plan: "生成配置计划", apply: "修正、读回并保存" }.each do |mode, description|
              opts.on("--#{mode}", description) do
                raise ArgumentError, "--discover、--plan、--apply 不能同时使用" if values[:topology_mode]

                values[:topology_mode] = mode
                values[:apply] = true if mode == :apply
              end
            end
            opts.on("--inventory-only", "只读取并过滤清单，不连接设备") { values[:inventory_only] = true }
            opts.on("--limit N", Integer, "最多选择 N 台可发现设备") do |value|
              raise OptionParser::InvalidArgument unless value.positive?

              values[:topology_limit] = value
            end
            opts.on("--description-format TEXT", "模板仅支持 %{neighbor}、%{port}") { |value| values[:environment]["NC_TOPOLOGY_DESCRIPTION_FORMAT"] = value }
            opts.on("--full-port-names", "不缩写邻居端口") { values[:environment]["NC_TOPOLOGY_ABBREVIATE"] = "false" }
            opts.on("--lowercase-ports", "邻居端口转换成小写") { values[:environment]["NC_TOPOLOGY_LOWERCASE"] = "true" }
          end

          # 正式 CLI 与批次示例共用并发、抽样、核验和成功策略选项。
          def self.add_execution(opts, values, mode: nil)
            opts.on("--refresh-inventory", "强制刷新清单；远端失败时回退已验证历史") { values[:force_refresh] = true }
            opts.on("--cache-only", "仅使用已验证的清单缓存，不查询远端") { values[:environment]["ND_CACHE_MODE"] = "only" }
            opts.on("--cache-mode MODE", %w[prefer only refresh], "清单缓存 prefer / only / refresh") do |value|
              values[:environment]["ND_CACHE_MODE"] = value
            end
            opts.on("-p", "--parallel N", Integer, "并发设备数，1 至 500") do |count|
              raise OptionParser::InvalidArgument unless (1..Settings::MAX_PARALLEL).cover?(count)

              values[:environment]["NC_PARALLEL"] = count.to_s
            end
            return if mode == :topology

            opts.on("--sample N", "--limit-per-vendor N", Integer, "每厂商抽样 1 至 5 台") do |count|
              Planner.validate_limit!(count)
              values[:limit] = count
            end
            opts.on("--tftp-root DIR", "本机 TFTP 服务器文件目录") { |path| values[:tftp_root] = path }
            opts.on("--all", "选择全部就绪设备") { values[:all] = true }
            opts.on("--success-policy POLICY", %w[strict selected verified], "成功判定：strict / selected / verified（TFTP 文件核验）") do |policy|
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
            raise ArgumentError, "--all 不能与抽样同时使用" if options[:all] && options[:limit]
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
              "--username USER" => ["NC_DEVICE_USERNAME", "设备登录用户名"],
              "--password PASSWORD" => ["NC_DEVICE_PASSWORD", "设备登录密码（可改用 --ask-password）"],
              "--enable-password PASSWORD" => ["NC_ENABLE_PASSWORD", "设备提权密码"],
              "--netdisco-url URL" => ["ND_URL", "Netdisco 地址"],
              "--netdisco-username USER" => ["ND_USERNAME", "Netdisco 用户名"],
              "--netdisco-password PASSWORD" => ["ND_PASSWORD", "Netdisco 密码"],
              "--directory DIR" => ["NC_BACKUP_DIRECTORY", "#{mode == :topology ? "拓扑报告" : "备份"}目录，相对启动目录"],
              "--config FILE" => ["NC_CONFIG", "YAML 配置，相对启动目录"]
            }.each do |flag, (key, description)|
              opts.on(flag, description) do |value|
                raise OptionParser::InvalidArgument if value.empty?

                values[:environment][key] = value
              end
            end
            opts.on("--env-file FILE", "最后叠加的环境文件，相对启动目录") { |path| values[:env_file] = path }
            opts.on("--show-config", "显示生效的非敏感设置与配置来源") { values[:show_config] = true }
            opts.on("--host-key-policy POLICY", %w[strict accept_new replace], "主机密钥策略：strict / accept_new / replace（变化时自动替换）") do |policy|
              values[:environment]["NC_HOST_KEY_POLICY"] = policy
            end
            opts.on("--known-hosts FILE", "持久保存主机密钥的文件") do |path|
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
            opts.on("--host IP", "选择单台设备，可重复") do |value|
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

            raise ArgumentError, "密码提示与显式密码不能同时使用" if values[:environment].key?(key)
            values[:environment][key] = CtxCli::Terminal.new(input: input, out: output).password(label: label)
          end
          private_class_method :read_password, :parser_for
        end
      end
    end
  end
end
