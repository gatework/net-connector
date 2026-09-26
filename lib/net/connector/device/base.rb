# frozen_string_literal: true

require "English"
require "forwardable"
require_relative "../engine/core"
require_relative "profile"
require_relative "running_config"
require_relative "interface_description"
require_relative "../operations"

module Net
  module Connector
    # 设备连接门面；厂商子类提供语法和钩子，组合对象负责实际执行。
    class Base
      extend Forwardable

      attr_reader :configuration, :command_timeout

      # 将连接状态查询委托给当前设备会话。
      def_delegators :@session, :connected?, :privileged?, :state
      # 将设备地址、账号和日志路径委托给连接配置。
      def_delegators :@configuration, :host, :username, :log_file

      class << self
        # 读取或声明连接器的厂商标识。
        def vendor(key = nil)
          return @vendor = key if key

          @vendor || (superclass.vendor if superclass.respond_to?(:vendor))
        end

        # 在子类中声明设备规则；没有块时返回当前类继承到的档案。
        def profile(&definition)
          return inherited_profile unless definition

          @profile = Profile.define(parent: inherited_profile, &definition)
        end

        # 让子类共享不可变父档案，子类声明时再生成自己的副本。
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@profile, profile)
        end

        private

        # 查找当前类或最近父类的设备档案。
        def inherited_profile
          return @profile if instance_variable_defined?(:@profile)

          parent = superclass
          parent.respond_to?(:profile) ? parent.profile : nil
        end
      end

      # 连接设备并执行代码块；无论正常返回、break、异常还是中断，都会释放会话资源。
      def self.open(**)
        raise ArgumentError, "open requires a block" unless block_given?

        device = new(**)
        begin
          device.connect
          yield device
        ensure
          active_error = $ERROR_INFO
          begin
            device.close
          rescue StandardError
            raise unless active_error
          end
        end
      end

      # 校验连接配置，创建对话语法、传输层、恢复器和会话对象。
      def initialize(configuration: nil, transport: nil, **settings)
        if configuration
          raise ArgumentError, "configuration cannot be combined with settings" unless settings.empty?
          raise ArgumentError, "configuration must be a Configuration" unless configuration.is_a?(Configuration)
        end
        @configuration = configuration || Configuration.new(**settings)
        @command_timeout = @configuration.command_timeout || default_command_timeout
        @dialogue = build_dialogue
        transport ||= Transports.build(@configuration, terminal_size: terminal_size)
        @session = Session.new(configuration: @configuration, dialogue: @dialogue, transport: transport,
                               recovery: Recovery.new(@configuration, legacy_arguments: legacy_ssh_arguments),
                               after_login: method(:after_login))
      end

      # 返回当前连接器使用的不可变设备档案，便于检查厂商声明。
      def profile = self.class.profile || Profile.default

      # 读取或声明连接器的厂商标识。
      def vendor = self.class.vendor

      # 只查询实现能力，不连接设备；不代表现场权限或固件验证成功。
      def supports?(capability)
        capability = capability.to_sym if capability.is_a?(String)
        case capability
        when :running_config, :backup
          !config_commands.empty?
        when :save_config
          !save_commands.empty?
        when :tftp_backup
          !profile.tftp_strategy.nil?
        when :neighbors, :interface_descriptions, :interface_description_changes
          !!profile.topology_strategy&.supports?(capability)
        else
          false
        end
      rescue NotImplementedError
        false
      end

      # 建立会话并返回当前设备对象。
      def connect
        @session.connect
        self
      end

      # 关闭会话及其传输资源。
      def close = @session.close

      # 将一条文本命令包装成脚本并执行。
      def execute(text, **, &)
        execute_script(Script.new([Command.new(text, **)]), &)
      end

      # 接收脚本或命令数组，统一交给单次会话执行。
      def execute_script(script, &)
        script = Script.new(script) unless script.is_a?(Script)
        perform_script(script, &)
      end

      # 使用简短名称执行脚本。
      alias run execute_script

      # 读取运行配置并返回清理后的配置结果。
      def running_config
        RunningConfig.new(self).call
      end

      # 执行命令并按厂商、命令或显式 TextFSM 模板返回结构化记录。
      def parse_command(command, template: nil, template_dir: nil)
        parser = Operations::ParseOutput.new(template_dir: template_dir)
        parser.call(execute(command).value!, template: template, vendor: vendor, command: command, host: host)
      end

      # 采集运行配置并使用指定 TextFSM 模板提取结构化记录。
      def parse_config(template:, template_dir: nil)
        parser = Operations::ParseOutput.new(template_dir: template_dir)
        parser.call(running_config.value!, template: template, host: host)
      end

      # 执行 CDP 或 LLDP 查询并返回统一的链路邻居记录。
      def neighbors = Operations::Topology.new(self).neighbors

      # 读取运行配置中的接口描述或端口名称。
      def interface_descriptions = Operations::Topology.new(self).descriptions

      # 以邻居和现有配置为证据，生成待确认的接口描述变更计划。
      def plan_interface_descriptions(abbreviate: true, lowercase: false, &formatter)
        Operations::Topology.new(self).plan_descriptions(abbreviate: abbreviate, lowercase: lowercase, &formatter)
      end

      # 明确确认且现场证据未变化时执行接口描述计划。
      def apply_interface_descriptions(plan, confirmed: false)
        Operations::Topology.new(self).apply(plan, confirmed: confirmed)
      end

      # 多步骤业务操作独占当前会话，内部脚本仍禁止回调重入。
      def with_operation(name, &block) = @session.with_operation(name, &block)

      # 采集配置并以原子方式保存为私有文件。
      # 采集失败时保留已有备份文件。
      def backup(path:)
        Operations::LocalBackup.new(self).call(path: path)
      end

      # 要求设备直接向 TFTP 服务器导出原生配置。
      # 完成仅表示设备报告传输成功，未读取服务器端文件。
      def tftp_backup(host:, path: nil, source_file: nil, vrf: nil)
        Operations::TftpBackup.new(self).call(host: host, path: path, source_file: source_file, vrf: vrf)
      end

      # 配置采集是设备的基础能力，两个公共入口共享同一流程。
      def collect_config = RunningConfig.new(self).call

      # 业务层可扩展脚本准备、响应校验和最终结果，所有钩子均在会话锁内执行。
      def execute_operation(script, name:, prompt: nil, after_command: nil, privilege: true, &finalize)
        perform_script(script, operation: name, prompt: prompt, after_command: after_command,
                       privilege: privilege, finalize: finalize)
      end

      # 返回已确认的提示，供业务层为只读采集绑定准确的结束条件。
      def current_prompt = @session.prompt

      # 将业务事件写入当前设备会话日志。
      def record_event(name, **details)
        @session.log_event(name, **details)
      end

      # 执行厂商保存配置命令；不支持时返回显式失败结果。
      def save_config
        if save_commands.empty?
          return Result.new(error: @session.error(UnsupportedOperation, "saving configuration is not supported",
                                                  phase: :save))
        end

        execute_script(save_commands)
      end

      # 进入特权模式，并把当前提示符记录到会话。
      def enable
        @session.perform(:enable) { @session.enable(enable_command, enable_prompt) }
        self
      end

      # 将会话交给人工交互；交互结束后会话按终端语义关闭。
      def interact(input: $stdin, output: $stdout, escape: "\x1d".b, timeout: nil)
        @session.interact(input: input, output: output, escape: escape, timeout: timeout)
      end

      # 返回读取运行配置所需的设备命令；厂商必须实现。
      def config_commands
        commands = profile.config_commands
        return commands if commands

        raise NotImplementedError, "#{self.class} must define running configuration commands"
      end

      # 返回保存配置命令；空数组表示设备不支持保存。
      def save_commands = profile.save_commands

      # 清理运行配置文本；厂商可移除设备回显噪声。
      def clean_config(text) = config_strategy.clean(text)

      # 返回不包含凭据的连接状态摘要。
      def inspect = "#<#{self.class} host=#{host.inspect} state=#{state}>"

      protected

      # 默认取最后一个已完成步骤；厂商可选择配置所在的业务步骤。
      def config_result_step(result) = config_strategy.result_step(result)

      # 匹配设备分页提示，供对话层自动发送翻页响应。
      def pager_pattern = profile.pager_pattern

      # 返回分页提示对应的响应字节。
      def pager_response = profile.pager_response

      # 匹配密码输入提示。
      def password_prompt = profile.password_prompt

      # 匹配用户名输入提示。
      def username_prompt = profile.username_prompt

      # 返回认证失败的设备输出模式。
      def authentication_error_patterns = profile.authentication_error_patterns

      # 返回命令失败的设备输出模式。
      def command_error_patterns = profile.command_error_patterns

      # 返回命令期间需要自动应答的确认对话。
      def confirmation_dialogues = profile.confirmation_interactions

      # 返回登录期间需要自动应答的附加对话。
      def login_dialogues = profile.login_interactions

      # 返回旧版 SSH 恢复使用的协商参数。
      def legacy_ssh_arguments = profile.legacy_ssh_arguments

      # 返回进入特权模式的命令；nil 表示不支持。
      def enable_command = profile.privilege_command

      # 匹配特权模式提示符。
      def enable_prompt = profile.privilege_prompt

      # 返回默认单条命令超时秒数。
      def default_command_timeout = profile.command_timeout

      # 返回可选终端大小。
      def terminal_size = profile.terminal_size

      # 返回登录完成提示；厂商必须实现。
      def login_prompt
        prompt = profile.login_prompt
        return prompt if prompt

        raise NotImplementedError, "#{self.class} must define login_prompt"
      end

      # 返回普通命令提示；厂商必须实现。
      def command_prompt
        prompt = profile.command_prompt
        return prompt if prompt

        raise NotImplementedError, "#{self.class} must define command_prompt"
      end

      # 登录成功后执行厂商初始化钩子。
      def after_login(_session, _response) end

      # 脚本开始前执行厂商批处理准备钩子。
      def before_batch(execution)
        return unless enable_command && execution.context.fetch(:privilege, true)

        execution.enable(enable_command, enable_prompt)
      end

      # 调整单条命令或返回 nil 跳过该命令。
      def prepare_command(command, _execution) = command

      # 单条命令完成后执行厂商后处理钩子。
      def after_command(_command, _response, _execution) end

      private

      # 采集器仅在持有会话锁的结果处理阶段绑定策略，让旧方法钩子的 super
      # 复用响应校验状态。其他 Fiber 的离线清理仍使用自己的临时策略。
      def with_config_strategy(strategy)
        previous = @config_strategy_scope
        @config_strategy_scope = [Fiber.current, strategy]
        yield
      ensure
        @config_strategy_scope = previous
      end

      def config_strategy
        scope = @config_strategy_scope
        scope && scope.first.equal?(Fiber.current) ? scope.last : RunningConfig.strategy(self)
      end

      # 将厂商提示、失败模式和对话钩子组装成不可变对话语法。
      def build_dialogue
        Dialogue.new(
          login_prompt: login_prompt, command_prompt: command_prompt,
          password_prompt: password_prompt, username_prompt: username_prompt, enable_prompt: enable_prompt,
          authentication_errors: authentication_error_patterns, command_errors: command_error_patterns,
          login_interactions: login_dialogues,
          command_interactions: [Interaction.new(pager_pattern, pager_response, capture: false),
                                 *confirmation_dialogues]
        )
      end

      # 在会话锁内运行脚本及业务回调，保留已完成步骤和统一错误边界。
      def perform_script(script, operation: nil, prompt: nil, after_command: nil, privilege: true,
                         finalize: nil, &on_step)
        return Result.new if script.empty?

        finish_step = lambda do |command, response, context|
          self.after_command(command, response, context)
          after_command&.call(command, response, context)
        end
        execution = Execution.new(session: @session, timeout: command_timeout,
                                  prepare: method(:prepare_command), after_command: finish_step, prompt: prompt)
        execution.context[:operation] = operation if operation
        execution.context[:privilege] = privilege
        @session.perform(:script) do
          before_batch(execution)
          result = execution.execute(script, &on_step)
          finalize ? finalize.call(result) : result
        end
      rescue Error => error
        Result.new(steps: execution ? execution.steps : [], error: error)
      end
    end
  end
end
