# frozen_string_literal: true

require_relative "../config/initializer"
require_relative "../config/defaults"

module Net
  module Connector
    module Netdisco
      class CLI
        # 首次运行的文件检查和创建问答；完成初始化后必须退出，不触发设备任务。
        class Setup
          ENVIRONMENT_TEMPLATE = <<~TEXT.freeze
            # 进程环境优先于此文件；命令行参数 > YAML > 环境默认值 > 内置默认值。
            # 下列凭据按实际认证方式取消注释并填写；不自动保存当前进程中的密码。
            # ND_URL=
            # ND_USERNAME=
            # ND_PASSWORD=
            # ND_API_KEY=
            # NC_DEVICE_USERNAME=
            # NC_DEVICE_PASSWORD=
            # NC_ENABLE_PASSWORD=
            # PostgreSQL 清单使用 ND_DB_HOST / ND_DB_NAME / ND_DB_USER / ND_DB_PASS。
            # ND_DB_HOST=
            # ND_DB_NAME=
            # ND_DB_USER=
            # ND_DB_PASS=
            # TFTP SSH 归档使用现有密钥/agent，或设置以下密码。
            # 密码含 # 或 $ 时请用单引号包裹，例如 KEY='your-password'。
            # NC_TFTP_SSH_PASSWORD=
            # 公共参数优先写入各入口 YAML；可在运行时使用 -p / --config / --directory。
            # NC_CONFIG 不设置时分别使用 examples/backup.yml 和 examples/topology.yml。
          TEXT

          # 保存调用方 IO 与路径；不读取标准输入、不加载凭据、不创建文件。
          def initialize(mode:, options:, env:, input:, output:, env_path: nil, directory: nil, load_env: false)
            @mode, @options, @env, @input, @output = mode, options, env, input, output
            @env_path, @directory, @load_env = env_path, directory, load_env
            @initializer = Config::Initializer.new(input: input, output: output)
          end

          # 先确认所有缺失文件的创建意愿，再独占发布；非终端仅接受显式 --init。
          def initialize_files?
            path = @options.fetch(:environment)["NC_CONFIG"] || @env["NC_CONFIG"]
            missing_config = path && missing?(path)
            missing_env = @env_path && missing?(@env_path)
            return !!@options[:init] unless missing_config || missing_env
            raise ArgumentError, "--interactive 需要交互终端；自动化请使用 --init --non-interactive" if @options[:interactive] && !terminal?

            create_config = missing_config && approved?(path, required: true)
            create_env = missing_env && approved?(@env_path, required: false)
            document = Config::Defaults.document(mode: @mode, values: public_values, directory: @directory) if create_config
            if create_config
              @initializer.create(path: path, document: document, interactive: questionnaire?, mode: @mode)
              @output.puts "已初始化配置：#{path}"
            end
            if create_env
              @initializer.create_environment(path: @env_path, contents: ENVIRONMENT_TEMPLATE)
              @output.puts "已初始化环境模板：#{@env_path}（未写入密码）"
            end
            stopped = create_config || create_env || @options[:init]
            @output.puts "请检查配置及凭据后再次运行；本次未读取清单、未连接设备。" if stopped
            @output.puts "HTTP 清单需设置 netdisco.url 或 ND_URL，并提供 ND_API_KEY 或 ND_USERNAME / ND_PASSWORD；设备凭据支持通用及厂商配置。" if create_config && document.dig("netdisco", "source") == "http"
            @output.puts "TFTP 请填写 tftp.server 或 tftp.servers，并按实际环境配置文件核验目录；未猜测服务器、VRF 或源接口。" if create_config && @mode == :tftp
            !!stopped
          end

          private

          # 缺失与无效文件分开处理，拒绝符号链接、目录及不可读取文件。
          def missing?(path)
            stat = File.lstat(path)
            raise ArgumentError, "配置路径必须是可读普通文件：#{path}" unless stat.file? && File.readable?(path)

            false
          rescue Errno::ENOENT
            true
          end

          # 标准输入凭据协议独占输入；只有真实终端才允许配置问答。
          def terminal?
            !@options[:stdin_credentials] && @input.respond_to?(:tty?) && @input.tty? && @output.respond_to?(:tty?) && @output.tty?
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
              raise ArgumentError, "缺少配置：#{path}；请先执行 --init --non-interactive 创建，或使用 --config 指定已有文件" if required

              return false
            end
            loop do
              @output.print "未找到 #{path}，是否创建？[y/N]："
              @output.flush
              line = @input.gets("\n")
              raise EOFError unless line

              answer = line.strip.downcase
              return true if %w[y yes].include?(answer)
              if answer.empty? || %w[n no].include?(answer)
                raise ArgumentError, "未创建必需配置：#{path}；本次停止" if required

                return false
              end
              @output.puts "请输入 y 或 n。"
            end
          end

          # CLI 参数覆盖已加载的公共环境值；敏感变量不在字段允许列表内。
          def public_values
            values = (@load_env ? @env.to_h : {}).merge(@options.fetch(:environment))
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
