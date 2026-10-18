# frozen_string_literal: true

require "optparse"
require_relative "../settings"
require_relative "../planner"
require_relative "../config_file"
require_relative "help"

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
            raise ArgumentError, "参数无效：并发数须为 1 至 50，抽样须为 1 至 5；使用 --help 查看参数", cause: nil
          end

          def self.parser_for(values, output:, program:, mode:, &additional)
            raise ArgumentError, "unknown CLI mode" unless %i[backup tftp topology].include?(mode)

            OptionParser.new do |opts|
              default = mode == :topology ? "默认只读规划" : "默认沿用配置"
              opts.banner = "用法：ruby #{File.basename(program)} [选项]（#{default}）\n命令行参数优先；未指定的项沿用配置及默认值。无筛选时选择全部就绪设备。"
              add_settings(opts, values)
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
                output.puts(mode == :topology ? opts : Help.common(opts))
                values[:help] = true
              end
              opts.on("--help-all", "显示完整选项（凭据、抽样、SSH、自动化等）") { output.puts opts; values[:help] = true }
            end
          end

          def self.add_terminal_options(opts, values)
            opts.on("--ask-password", "隐藏输入设备密码") { values[:ask_password] = true }
            opts.on("--ask-netdisco-password", "隐藏输入 Netdisco 密码") { values[:ask_netdisco_password] = true }
            opts.on("--quiet", "--no-progress", "关闭进度；可配合 --json") { values[:no_progress] = true }
            opts.on("--verbose", "显示逐条登录和命令事件") { values[:verbose] = true }
            opts.on("--json", "在 stdout 输出 JSON；默认显示可读摘要") { values[:json] = true }
            opts.on("--stdin-credentials", "从标准输入读取凭据并等待 RUN") { values[:stdin_credentials] = true }
            opts.on("--interactive", "缺少配置时交互填写，已有配置保持原样") { values[:interactive] = true }
            opts.on("--non-interactive", "缺少配置时使用默认值，不进行问答") { values[:interactive] = false }
          end

          def self.add_topology(opts, values)
            { discover: "发现邻居并检查描述", plan: "生成配置计划", apply: "修正、读回并保存" }.each do |mode, description|
              opts.on("--#{mode}", description) do
                raise ArgumentError, "topology modes are mutually exclusive" if values[:topology_mode]

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
            opts.on("-c", "--concurrency N", Integer, "并发设备数，1 至 50") do |count|
              raise OptionParser::InvalidArgument unless (1..Settings::MAX_CONCURRENCY).cover?(count)

              values[:environment]["NC_CONCURRENCY"] = count.to_s
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

          # 公开 CLI 参数进入 overrides，凭据留在 environment；内部键不会重新开放已移除环境设置。
          def self.settings(options, env: ENV, load_env: false)
            raise ArgumentError, "--all 不能与抽样同时使用" if options[:all] && options[:limit]
            if options[:host] && options.fetch(:environment).key?("NC_INCLUDE_HOSTS")
              raise ArgumentError, "--host cannot be combined with --hosts"
            end

            environment = environment(options, env: env)
            path = environment["NC_CONFIG"]
            defaults = path && !path.empty? ? ConfigFile.load(path) : {}
            keys = ConfigFile::FIELDS.values.flat_map { |fields| fields.values.map(&:first) }
            if load_env
              # 显式启用时，公开环境值只填补 YAML；CLI 覆盖与凭据来源仍分开处理。
              defaults = env.to_h.slice(*keys).merge(defaults)
              environment = environment.reject { |key, _| keys.include?(key) }
            end
            overrides = options.fetch(:environment).slice(*keys)
            environment = environment.reject { |key, _| overrides.key?(key) && !Settings::ENVIRONMENT_KEYS.include?(key) }
            { source: "ND_SOURCE", query: "ND_QUERY", query_params: "ND_QUERY_PARAMS",
              max_script_output_bytes: "NC_MAX_SCRIPT_OUTPUT_BYTES", host: "NC_INCLUDE_HOSTS",
              limit: "NC_SAMPLE_PER_VENDOR", tftp_root: "NC_TFTP_ROOT" }.each do |option, key|
              overrides[key] = options[option].to_s if options.key?(option)
            end
            overrides["NC_SAMPLE_PER_VENDOR"] = nil if options[:all]
            Settings.new(env: environment, defaults: defaults, overrides: overrides)
          end

          # 共用配置与凭据参数登记；具体入口决定后续预览、执行或导出。
          def self.add_settings(opts, values)
            add_filters(opts, values)
            {
              "--username USER" => ["NC_DEVICE_USERNAME", "设备登录用户名"],
              "--password PASSWORD" => ["NC_DEVICE_PASSWORD", "设备登录密码（可改用 --ask-password）"],
              "--enable-password PASSWORD" => ["NC_ENABLE_PASSWORD", "设备提权密码"],
              "--netdisco-url URL" => ["ND_URL", "Netdisco 地址"],
              "--netdisco-username USER" => ["ND_USERNAME", "Netdisco 用户名"],
              "--netdisco-password PASSWORD" => ["ND_PASSWORD", "Netdisco 密码"],
              "--directory DIR" => ["NC_BACKUP_DIRECTORY", "备份目录，相对项目根目录"],
              "--config FILE" => ["NC_CONFIG", "YAML 配置，相对项目根目录"]
            }.each do |flag, (key, description)|
              opts.on(flag, description) do |value|
                raise OptionParser::InvalidArgument if value.empty?

                values[:environment][key] = value
              end
            end
            opts.on("--host-key-policy POLICY", %w[strict accept_new replace], "主机密钥策略：strict / accept_new / replace（变化时自动替换）") do |policy|
              values[:environment]["NC_HOST_KEY_POLICY"] = policy
            end
            opts.on("--known-hosts FILE", "持久保存主机密钥的文件") do |path|
              values[:environment]["NC_KNOWN_HOSTS"] = path
            end
          end

          # 同类 CLI 筛选替换 YAML；重复参数在本次调用内合并，绝不把范围展开为地址列表。
          def self.add_filters(opts, values)
            {
              "--hosts PATTERNS" => ["NC_INCLUDE_HOSTS", "包含地址、网段或范围，逗号分隔"],
              "--exclude-hosts PATTERNS" => ["NC_EXCLUDE_HOSTS", "排除地址、网段或范围"],
              "--name PATTERNS" => ["NC_INCLUDE_NAMES", "包含设备名称，可重复或逗号分隔"],
              "--exclude-name PATTERNS" => ["NC_EXCLUDE_NAMES", "排除设备名称，可重复或逗号分隔"],
              "--vendor NAMES" => ["NC_INCLUDE_VENDORS", "包含连接器厂商名"],
              "--exclude-vendor NAMES" => ["NC_EXCLUDE_VENDORS", "排除连接器厂商名"]
            }.each do |flag, (key, description)|
              opts.on(flag, description) do |value|
                items = value.split(",", -1).map(&:strip)
                raise OptionParser::InvalidArgument if items.empty? || items.any?(&:empty?)

                previous = values[:environment][key]&.split(",") || []
                values[:environment][key] = (previous + items).uniq.join(",")
              end
            end
            opts.on("--name-match MODE", %w[contains prefix glob], "名称匹配方式：contains / prefix / glob") do |value|
              values[:environment]["NC_NAME_MATCH"] = value
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
            raise ArgumentError, "密码提示需要交互终端；自动化任务可使用环境变量或 --stdin-credentials" unless input.tty?
            require "io/console"
            output.print "#{label}："
            output.flush
            password = input.noecho { |terminal| terminal.gets("\n") }&.chomp("\n")
            output.puts
            raise ArgumentError, "密码不能为空" if password.nil? || password.empty?

            values[:environment][key] = password
          end
          private_class_method :read_password, :parser_for
        end
      end
    end
  end
end
