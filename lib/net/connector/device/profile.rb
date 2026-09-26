# frozen_string_literal: true

require "expect/pty"
require_relative "../engine/dialogue"

module Net
  module Connector
    # 描述设备命令行规则的不可变值对象；只承载声明式配置，不承载运行状态。
    class Profile
      DEFAULT_PAGER_PATTERN = /(?:\A|(?<=[\r\n]))[ \t]*(?:--More--|---- More ----)[ \t\x00\x08]*(?=\r|\n|\z)/i.freeze
      DEFAULT_AUTHENTICATION_ERROR_PATTERNS = [
        /(?:authentication failed|permission denied|access denied|login incorrect)/i
      ].freeze
      DEFAULT_PASSWORD_PROMPT = /password:\s*\z/i.freeze
      DEFAULT_USERNAME_PROMPT = /(?:login|username|name):\s*\z/i.freeze
      DEFAULT_PRIVILEGE_PROMPT = /#\s*\z/.freeze
      DEFAULT_LEGACY_SSH_ARGUMENTS = ["-1"].freeze

      attr_reader :config_commands, :save_commands,
                  :login_prompt, :command_prompt, :username_prompt, :password_prompt,
                  :privilege_prompt, :pager_pattern, :pager_response,
                  :authentication_error_patterns, :command_error_patterns,
                  :login_interactions, :confirmation_interactions, :legacy_ssh_arguments,
                  :privilege_command, :command_timeout, :terminal_size, :tftp_strategy, :topology_strategy, :running_config_strategy

      # 使用默认的公共规则创建空设备档案；登录和命令提示符仍由厂商声明。
      def self.default
        @default ||= new
      end

      # 在继承档案的基础上执行一次声明块，生成新的不可变设备档案。
      def self.define(parent: nil, &definition)
        raise ArgumentError, "profile requires a block" unless definition

        builder = Builder.new(parent || default)
        builder.instance_eval(&definition)
        builder.build
      end

      # 校验并冻结设备命令、提示符、交互和连接参数。
      def initialize(config_commands: nil, save_commands: [],
                     login_prompt: nil, command_prompt: nil,
                     username_prompt: DEFAULT_USERNAME_PROMPT, password_prompt: DEFAULT_PASSWORD_PROMPT,
                     privilege_prompt: DEFAULT_PRIVILEGE_PROMPT,
                     pager_pattern: DEFAULT_PAGER_PATTERN, pager_response: " ",
                     authentication_error_patterns: DEFAULT_AUTHENTICATION_ERROR_PATTERNS,
                     command_error_patterns: [], login_interactions: [], confirmation_interactions: [],
                     legacy_ssh_arguments: DEFAULT_LEGACY_SSH_ARGUMENTS, privilege_command: nil,
                     command_timeout: 25, terminal_size: nil, tftp_strategy: nil, topology_strategy: nil, running_config_strategy: nil)
        @config_commands = command_list(config_commands, :config_commands, allow_nil: true)
        @save_commands = command_list(save_commands, :save_commands)
        @login_prompt = pattern(login_prompt, :login_prompt, allow_nil: true)
        @command_prompt = pattern(command_prompt, :command_prompt, allow_nil: true)
        @username_prompt = pattern(username_prompt, :username_prompt)
        @password_prompt = pattern(password_prompt, :password_prompt)
        @privilege_prompt = pattern(privilege_prompt, :privilege_prompt)
        @pager_pattern = pattern(pager_pattern, :pager_pattern)
        @pager_response = response_text(pager_response, :pager_response)
        @authentication_error_patterns = patterns(authentication_error_patterns, :authentication_error_patterns)
        @command_error_patterns = patterns(command_error_patterns, :command_error_patterns)
        @login_interactions = interactions(login_interactions, :login_interactions)
        @confirmation_interactions = interactions(confirmation_interactions, :confirmation_interactions)
        @legacy_ssh_arguments = strings(legacy_ssh_arguments, :legacy_ssh_arguments)
        @privilege_command = optional_text(privilege_command, :privilege_command)
        @command_timeout = duration(command_timeout, :command_timeout)
        @terminal_size = validate_terminal_size(terminal_size)
        @running_config_strategy = strategy_class(running_config_strategy, :running_config_strategy,
                                                  %i[clean result_step prompt_text check_response])
        @tftp_strategy = strategy_class(tftp_strategy, :tftp_strategy,
                                        %i[source_file default_path remote_path script complete?])
        @topology_strategy = strategy_class(topology_strategy, :topology_strategy,
                                            %i[neighbor_command neighbor_template expected_neighbor_count empty_neighbor_output?
                                               protocol description_template interface_key configuration_interface
                                               decode_description enter_configuration change_commands finish_commands script_command])
        if @topology_strategy && !@topology_strategy.respond_to?(:supports?)
          raise ArgumentError, "topology_strategy must expose supports?"
        end
        freeze
      end

      # 返回一份供子类声明块继续编辑的关键字参数。
      def to_h
        {
          config_commands: config_commands,
          save_commands: save_commands,
          login_prompt: login_prompt,
          command_prompt: command_prompt,
          username_prompt: username_prompt,
          password_prompt: password_prompt,
          privilege_prompt: privilege_prompt,
          pager_pattern: pager_pattern,
          pager_response: pager_response,
          authentication_error_patterns: authentication_error_patterns,
          command_error_patterns: command_error_patterns,
          login_interactions: login_interactions,
          confirmation_interactions: confirmation_interactions,
          legacy_ssh_arguments: legacy_ssh_arguments,
          privilege_command: privilege_command,
          command_timeout: command_timeout,
          terminal_size: terminal_size,
          tftp_strategy: tftp_strategy,
          topology_strategy: topology_strategy,
          running_config_strategy: running_config_strategy
        }
      end

      # 返回档案中最有用的设备规则摘要。
      def inspect
        "#<#{self.class} commands=#{config_commands&.size || 0} " \
          "save_commands=#{save_commands.size}>"
      end

      private

      # 校验静态接口，不构造策略实例或触发设备 I/O。
      def strategy_class(value, name, required_methods)
        return nil if value.nil?
        unless value.is_a?(Class) && (required_methods - value.public_instance_methods).empty?
          raise ArgumentError, "#{name} must be a strategy class implementing #{required_methods.join(", ")}"
        end

        value
      end

      # 校验单条命令数组并复制为深度不可变值。
      def command_list(value, name, allow_nil: false)
        return nil if allow_nil && value.nil?
        unless value.is_a?(Array)
          raise ArgumentError, "#{name} must be an Array of command strings"
        end

        value.map do |command|
          unless command.is_a?(String) && !command.strip.empty? && !command.match?(/[\r\n\x00]/)
            raise ArgumentError, "#{name} must contain nonempty single-line commands"
          end

          command.dup.freeze
        end.freeze
      end

      # 校验提示模式并复制为不可变正则表达式。
      def pattern(value, name, allow_nil: false)
        return nil if allow_nil && value.nil?
        unless value.is_a?(Regexp) && !value.match?("")
          raise ArgumentError, "#{name} must be a nonempty Regexp"
        end

        value.dup.freeze
      end

      # 校验正则表达式列表并冻结每一项。
      def patterns(values, name)
        unless values.is_a?(Array)
          raise ArgumentError, "#{name} must be an Array of Regexp objects"
        end

        values.map { |value| pattern(value, name) }.freeze
      end

      # 校验交互对象列表并冻结列表。
      def interactions(values, name)
        unless values.is_a?(Array) && values.all?(Interaction)
          raise ArgumentError, "#{name} must be an Array of Interaction objects"
        end

        values.dup.freeze
      end

      # 校验并复制字符串数组。
      def strings(values, name)
        unless values.is_a?(Array) && values.all?(String)
          raise ArgumentError, "#{name} must be an Array of strings"
        end

        values.map { |value| value.dup.freeze }.freeze
      end

      # 校验可选单行文本。
      def optional_text(value, name)
        return if value.nil?
        text(value, name)
      end

      # 校验并复制单行文本。
      def text(value, name)
        unless value.is_a?(String) && !value.match?(/[\r\n\x00]/)
          raise ArgumentError, "#{name} must be a single-line String"
        end

        value.dup.freeze
      end

      # 校验并复制分页或交互响应；响应可以包含换行。
      def response_text(value, name)
        raise ArgumentError, "#{name} must be a String" unless value.is_a?(String)

        value.dup.freeze
      end

      # 校验默认命令超时。
      def duration(value, name)
        result = Expect.duration(value)
        raise ArgumentError, "#{name} must be finite" unless result

        result
      end

      # 校验终端宽高并冻结数组。
      def validate_terminal_size(value)
        return if value.nil?
        unless value.is_a?(Array) && value.size == 2 && value.all? { |dimension| dimension.is_a?(Integer) && dimension.positive? }
          raise ArgumentError, "terminal_size must contain two positive Integers"
        end

        value.dup.freeze
      end
    end
  end
end

require_relative "profile/builder"
