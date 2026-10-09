# frozen_string_literal: true

require "English"
require "forwardable"
require_relative "../engine/core"
require_relative "profile"
require_relative "running_config"
require_relative "save_config"
require_relative "local_backup"
require_relative "tftp"
require_relative "topology"
require_relative "../textfsm"

module Net
  module Connector
    # 设备连接门面；厂商子类提供语法和钩子，组合对象负责实际执行。
    class Base
      extend Forwardable
      include RunningConfig::Capability
      include SaveConfig
      include LocalBackup::Capability
      include Tftp::Capability
      include Topology::Capability
      include TextFSM::Capability

      attr_reader :configuration, :command_timeout

      def_delegators :@session, :connected?, :privileged?, :state
      def_delegators :@configuration, :host, :username, :log_file

      class << self
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
      def execute_command(text, **, &)
        execute_script(Script.new([Command.new(text, **)]), &)
      end

      # 接收脚本或命令数组，统一交给单次会话执行。
      def execute_script(script, &)
        script = Script.new(script) unless script.is_a?(Script)
        perform_script(script, &)
      end

      # 多步骤业务操作独占当前会话，内部脚本仍禁止回调重入。
      def with_operation(name, &) = @session.with_operation(name, &)

      # 业务层可扩展脚本准备、响应校验和最终结果，所有钩子均在会话锁内执行。
      def execute_operation(script, name:, prompt: nil, after_command: nil, privilege: true, &finalize)
        perform_script(script, operation: name, prompt: prompt, after_command: after_command,
                       privilege: privilege, finalize: finalize)
      end

      # 返回已确认的提示，供业务层为只读采集绑定准确的结束条件。
      def current_prompt = @session.prompt

      # 将业务事件写入当前设备会话日志。
      def log_event(name, **details)
        @session.log_event(name, **details)
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

      def inspect = "#<#{self.class} host=#{host.inspect} state=#{state}>"

      protected

      def pager_pattern = profile.pager_pattern

      def pager_response = profile.pager_response

      def password_prompt = profile.password_prompt

      def username_prompt = profile.username_prompt

      def authentication_error_patterns = profile.authentication_error_patterns

      def command_error_patterns = profile.command_error_patterns

      # 返回命令期间需要自动应答的确认对话。
      def confirmation_interactions = profile.confirmation_interactions

      # 返回登录期间需要自动应答的附加对话。
      def login_interactions = profile.login_interactions

      def legacy_ssh_arguments = profile.legacy_ssh_arguments

      def enable_command = profile.privilege_command

      def enable_prompt = profile.privilege_prompt

      def default_command_timeout = profile.command_timeout

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

      # 将厂商提示、失败模式和对话钩子组装成不可变对话语法。
      def build_dialogue
        Dialogue.new(
          login_prompt: login_prompt, command_prompt: command_prompt,
          password_prompt: password_prompt, username_prompt: username_prompt, enable_prompt: enable_prompt,
          authentication_errors: authentication_error_patterns, command_errors: command_error_patterns,
          login_interactions: login_interactions,
          command_interactions: [Interaction.new(pager_pattern, pager_response, capture: false),
                                 *confirmation_interactions]
        )
      end

      # 在会话锁内运行脚本及业务回调，保留已完成步骤和统一错误边界。
      def perform_script(script, operation: nil, prompt: nil, after_command: nil, privilege: true,
                         finalize: nil, &on_step)
        return Result.new if script.empty?

        execution = build_execution(operation: operation, prompt: prompt, after_command: after_command, privilege: privilege)
        output_sensitive = script.any?(&:output_sensitive?)
        result = nil
        @session.perform(:script) do
          @session.log_script(operation: operation, steps: execution.steps) do
            @session.with_sensitive_output(output_sensitive) { before_batch(execution) }
            result = execution.execute_script(script, &on_step)
            sensitive_result = output_sensitive || script.any?(&:sensitive?) || execution.sensitive?
            @session.with_sensitive_output(sensitive_result) do
              result = finalize_script_result(result, finalize)
            end
          end
        end
      rescue Error => error
        # 脚本完成后的日志收尾仍可能失败，已经生成的配置与主错误保持权威。
        if result.is_a?(Result)
          return Result.new(steps: result.steps, config: result.config, error: result.error || error)
        end

        Result.new(steps: execution ? execution.steps : [], error: error)
      end

      def build_execution(operation:, prompt:, after_command:, privilege:)
        finish_step = lambda do |command, response, context|
          self.after_command(command, response, context)
          after_command&.call(command, response, context)
        end
        execution = Execution.new(session: @session, timeout: command_timeout,
                                  prepare: method(:prepare_command), after_command: finish_step, prompt: prompt)
        execution.context[:operation] = operation if operation
        execution.context[:privilege] = privilege
        execution
      end

      # 回调也可直接返回失败；与抛错共用脱敏边界，保留已完成步骤及业务配置。
      def finalize_script_result(result, finalize)
        result = finalize ? finalize.call(result) : result
        return result unless result.is_a?(Result) && result.failure?

        Result.new(steps: result.steps, config: result.config,
                   error: @session.normalize_error(result.error, phase: :script))
      end
    end
  end
end
