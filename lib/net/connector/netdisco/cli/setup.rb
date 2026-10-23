# frozen_string_literal: true

require "fileutils"
require "ctx_cli/terminal"
require_relative "../config/initializer"
require_relative "../config/defaults"

module Net
  module Connector
    module Netdisco
      class CLI
        # 首次运行的文件检查和创建问答；完成初始化后必须退出，不触发设备任务。
        class Setup
          ENVIRONMENT_TEMPLATE = <<~TEXT.freeze
            # Process environment takes precedence over this file; CLI > original process environment > YAML > .env > built-in defaults.
            # Uncomment and fill in credentials for the authentication method in use; current process passwords are not saved automatically.
            # ND_URL=
            # ND_USERNAME=
            # ND_PASSWORD=
            # ND_API_KEY=
            # NC_DEVICE_USERNAME=
            # NC_DEVICE_PASSWORD=
            # NC_ENABLE_PASSWORD=
            # PostgreSQL inventory uses ND_DB_HOST / ND_DB_NAME / ND_DB_USER / ND_DB_PASS.
            # ND_DB_HOST=
            # ND_DB_NAME=
            # ND_DB_USER=
            # ND_DB_PASS=
            # TFTP SSH archiving uses existing keys/agent, or the password below.
            # Wrap passwords containing # or $ in single quotes, for example KEY='your-password'.
            # NC_TFTP_SSH_PASSWORD=
            # Prefer each entrypoint's YAML for common options; use -p / --config / --directory at runtime.
            # Without NC_CONFIG, configuration is discovered in system, user, entrypoint and startup directories, in that order.
          TEXT

          # 保存调用方 IO 与路径；不读取标准输入、不加载凭据、不创建文件。
          def initialize(mode:, options:, input:, output:, configuration:, directory: nil)
            @mode, @options, @input, @output = mode, options, input, output
            @directory = directory
            @configuration = configuration
            @initializer = Config::Initializer.new(input: input, output: output)
          end

          # 先确认所有缺失文件的创建意愿，再独占发布；非终端仅接受显式 --init。
          def initialize_files?
            @configuration.load_environment(allow_missing: !!(@options[:init] || @options[:interactive]))
            path = @configuration.init_config
            @env_path = @configuration.init_env_file
            return false unless @options[:init] || @options[:interactive] == true

            missing_config = path && missing?(path)
            missing_env = @env_path && missing?(@env_path)
            return !!@options[:init] unless missing_config || missing_env
            raise ArgumentError, "--interactive requires an interactive terminal; use --init --non-interactive for automation" if @options[:interactive] && !terminal?

            create_config = missing_config && approved?(path, required: true)
            create_env = missing_env && approved?(@env_path, required: false)
            document = create_configuration(path) if create_config
            if create_env
              FileUtils.mkdir_p(File.dirname(File.expand_path(@env_path)), mode: 0o700)
              @initializer.create_environment(path: @env_path, contents: ENVIRONMENT_TEMPLATE)
              @output.puts "Environment template initialized: #{@env_path}(passwords were not written)"
            end
            stopped = create_config || create_env || @options[:init]
            @output.puts "Check configuration and credentials, then run again; inventory was not read and no devices were connected." if stopped
            @output.puts "HTTP inventory requires netdisco.url or ND_URL and ND_API_KEY or ND_USERNAME / ND_PASSWORD; device credentials support common and per-vendor settings." if create_config && document.dig("netdisco", "source") == "http"
            @output.puts "For TFTP, set tftp.server or tftp.servers and the file verification directory for your environment; server, VRF and source interface are not inferred." if create_config && @mode == :tftp
            !!stopped
          end

          private

          # 先验证有效值；继承并发只用于提示，CLI 或问答的明确选择才写入 YAML。
          def create_configuration(path)
            document = Config::Defaults.document(mode: @mode, values: public_values, directory: @directory)
            policy = Settings.new(env: {}, defaults: Config.parse(document)).snapshot(mode: :show_config)
            inherited_parallel = @mode == :topology ? policy.topology_options.parallel : policy.parallel
            parallel_section = @mode == :topology ? "topology" : "backup"
            %w[backup topology].each do |section|
              next if section == parallel_section && @options.fetch(:environment).key?("NC_PARALLEL")

              document[section]&.delete("parallel")
            end
            FileUtils.mkdir_p(File.dirname(File.expand_path(path)), mode: 0o700)
            @initializer.create(path: path, document: document, interactive: questionnaire?, mode: @mode, inherited_parallel: inherited_parallel)
            @output.puts "Configuration initialized: #{path}"
            document
          end

          # 缺失与无效文件分开处理，拒绝符号链接、目录及不可读取文件。
          def missing?(path)
            stat = File.lstat(path)
            raise ArgumentError, "Configuration path must be a readable regular file: #{path}" unless stat.file? && File.readable?(path)

            false
          rescue Errno::ENOENT
            true
          end

          # 标准输入凭据协议独占输入；只有真实终端才允许配置问答。
          def terminal?
            !@options[:stdin_credentials] && CtxCli::Terminal.tty?(@input, @output)
          end

          # 创建和定制为独立选择；显式 --init 默认直接生成已识别值。
          def questionnaire?
            return false if @options[:interactive] == false || @options[:stdin_credentials]
            return !!@options[:interactive] if @options[:init]

            terminal?
          end

          # 不存在的必需 YAML 不可静默忽略；可选 .env 缺失不妨碍使用进程凭据。
          def approved?(path, required:)
            return true if @options[:init]
            unless terminal? && @options[:interactive] != false
              raise ArgumentError, "Missing configuration: #{path}; first run --init --non-interactive to create it, or use --config to select an existing file" if required

              return false
            end
            loop do
              @output.print "Not found: #{path}; create it? [y/N]: "
              @output.flush
              line = @input.gets("\n")
              raise EOFError unless line

              answer = line.strip.downcase
              return true if %w[y yes].include?(answer)
              if answer.empty? || %w[n no].include?(answer)
                raise ArgumentError, "Required configuration was not created: #{path}; stopped" if required

                return false
              end
              @output.puts "Enter y or n."
            end
          end

          # CLI 参数覆盖已加载的公共环境值；敏感变量不在字段允许列表内。
          def public_values
            values = @configuration.environment.merge(@options.fetch(:environment))
            { source: "ND_SOURCE", query: "ND_QUERY", query_params: "ND_QUERY_PARAMS", host: "NC_INCLUDE_HOSTS",
              limit: "NC_SAMPLE_PER_VENDOR", topology_limit: "NC_TOPOLOGY_LIMIT", tftp_root: "NC_TFTP_ROOT" }.each do |option, key|
              values[key] = @options[option].to_s if @options.key?(option)
            end
            values.delete("NC_SAMPLE_PER_VENDOR") if @options[:all]
            if @mode == :topology
              { "NC_PARALLEL" => "NC_TOPOLOGY_PARALLEL", "NC_BACKUP_DIRECTORY" => "NC_TOPOLOGY_DIRECTORY" }.each do |key, target|
                values[target] = @options.fetch(:environment)[key] if @options.fetch(:environment).key?(key)
              end
            end
            values
          end
        end
      end
    end
  end
end
