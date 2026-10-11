# frozen_string_literal: true

require "optparse"
require_relative "../settings"
require_relative "../planner"
require_relative "../config_file"

module Net
  module Connector
    module Netdisco
      class CLI
        # 可注入参数与输入输出的备份选项，不退出宿主进程。
        class Options
          # 复制参数数组，返回选项或帮助标记；非法输入抛错，不退出宿主进程。
          def self.parse(argv: ARGV, input: $stdin, output: $stdout, error: $stderr, program: $PROGRAM_NAME)
            values = { environment: {}, json: false, verbose: false, stdin_credentials: false }
            parser = parser_for(values, output: output, program: program)
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

          def self.parser_for(values, output:, program:)
            OptionParser.new do |opts|
              opts.banner = "用法：ruby #{File.basename(program)} [选项]（默认全量）"
              add_settings(opts, values)
              add_execution(opts, values)
              opts.on("--ask-password", "隐藏输入设备密码") { values[:ask_password] = true }
              opts.on("--ask-netdisco-password", "隐藏输入 Netdisco 密码") { values[:ask_netdisco_password] = true }
              opts.on("--no-progress", "关闭进度显示") { values[:no_progress] = true }
              opts.on("--verbose", "显示逐条登录和命令事件") { values[:verbose] = true }
              opts.on("--json", "在 STDOUT 输出计划和结果 JSON") { values[:json] = true }
              opts.on("--stdin-credentials", "从标准输入读取凭据并等待 RUN") { values[:stdin_credentials] = true }
              opts.on("-h", "--help", "显示帮助") { output.puts opts; values[:help] = true }
            end
          end

          # 正式 CLI 与批次示例共用并发、抽样、核验和成功策略选项。
          def self.add_execution(opts, values)
            opts.on("-c", "--concurrency N", Integer, "并发设备数，1 至 50") do |count|
              raise OptionParser::InvalidArgument unless (1..Settings::MAX_CONCURRENCY).cover?(count)

              values[:environment]["NC_CONCURRENCY"] = count.to_s
            end
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
          def self.settings(options, env: ENV)
            raise ArgumentError, "--all 不能与抽样同时使用" if options[:all] && options[:limit]

            environment = environment(options, env: env)
            path = environment["NC_CONFIG"]
            defaults = path && !path.empty? ? ConfigFile.load(path) : {}
            keys = ConfigFile::FIELDS.values.flat_map { |fields| fields.values.map(&:first) }
            overrides = options.fetch(:environment).slice(*keys)
            environment = environment.reject { |key, _| overrides.key?(key) && !Settings::ENVIRONMENT_KEYS.include?(key) }
            { source: "ND_SOURCE", query: "ND_QUERY", query_params: "ND_QUERY_PARAMS",
              max_script_output_bytes: "NC_MAX_SCRIPT_OUTPUT_BYTES", host: "NC_INCLUDE_HOSTS",
              limit: "NC_SAMPLE_PER_VENDOR" }.each do |option, key|
              overrides[key] = options[option].to_s if options.key?(option)
            end
            overrides["NC_SAMPLE_PER_VENDOR"] = nil if options[:all]
            Settings.new(env: environment, defaults: defaults, overrides: overrides)
          end

          # 共用配置与凭据参数登记；具体入口决定后续预览、执行或导出。
          def self.add_settings(opts, values)
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
            password = input.noecho(&:gets)&.chomp
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
