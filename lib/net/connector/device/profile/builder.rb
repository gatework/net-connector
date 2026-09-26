# frozen_string_literal: true

module Net
  module Connector
    class Profile
      # 构造器把声明块中的领域语言转换为设备档案字段。
      class Builder
        # 保存继承值并提供 commands、prompts 等有限的声明入口。
        def initialize(parent)
          @values = parent.to_h
        end

        # 声明运行配置和保存配置命令。
        def commands(&definition)
          check_block!(:commands, definition)
          commands = Commands.new(
            @values[:config_commands], @values[:save_commands]
          )
          commands.instance_eval(&definition)
          @values[:config_commands] = commands.config_commands
          @values[:save_commands] = commands.save_commands
          self
        end

        # 声明登录、命令、凭据和提权提示符。
        def prompts(&definition)
          check_block!(:prompts, definition)
          Prompts.new(@values).instance_eval(&definition)
          self
        end

        # 声明分页模式及自动翻页响应。
        def pager(&definition)
          check_block!(:pager, definition)
          Pager.new(@values).instance_eval(&definition)
          self
        end

        # 声明认证失败和命令失败的输出模式。
        def errors(&definition)
          check_block!(:errors, definition)
          Errors.new(@values).instance_eval(&definition)
          self
        end

        # 声明登录挑战和命令确认交互。
        def interactions(&definition)
          check_block!(:interactions, definition)
          interactions = Interactions.new(@values)
          interactions.instance_eval(&definition)
          @values[:login_interactions] = interactions.login_interactions
          @values[:confirmation_interactions] = interactions.confirmation_interactions
          self
        end

        # 声明进入特权模式所需的命令和提示符。
        def privilege(&definition)
          check_block!(:privilege, definition)
          Privilege.new(@values).instance_eval(&definition)
          self
        end

        # 声明旧版 SSH 协商参数。
        def ssh(&definition)
          check_block!(:ssh, definition)
          Ssh.new(@values).instance_eval(&definition)
          self
        end

        # 设置设备命令的默认超时秒数。
        def command_timeout(seconds)
          @values[:command_timeout] = seconds
          self
        end

        # 设置避免设备自动换行的终端宽高。
        def terminal_size(width, height = nil)
          @values[:terminal_size] = height.nil? ? width : [width, height]
          self
        end

        # 绑定已加载的策略类；nil 明确关闭继承的业务能力。
        def tftp_strategy(klass)
          @values[:tftp_strategy] = klass
          self
        end

        # 指定运行配置采集策略，覆盖继承的厂商规则。
        def running_config_strategy(klass)
          @values[:running_config_strategy] = klass
          self
        end

        # 指定邻居发现和描述下发策略，nil 表示关闭能力。
        def topology_strategy(klass)
          @values[:topology_strategy] = klass
          self
        end

        # 将声明字段校验并构造成不可变档案。
        def build = Profile.new(**@values)

        private

        # 块式声明入口必须有明确的子 DSL，避免静默忽略配置。
        def check_block!(name, definition)
          raise ArgumentError, "#{name} requires a block" unless definition
        end

        # 命令集合的声明对象。
        class Commands
          attr_reader :config_commands, :save_commands

          # 复制继承的命令，后续修改不会污染父类档案。
          def initialize(config_commands, save_commands)
            @config_commands = config_commands&.dup
            @save_commands = save_commands.dup
          end

          # 声明读取运行配置的命令序列。
          def running_config(*commands)
            @config_commands = commands.flatten
          end

          # 声明保存配置的命令序列。
          def save_config(*commands)
            @save_commands = commands.flatten
          end
        end

        # 提示符的声明对象。
        class Prompts
          # 将登录、命令、用户名、密码和特权提示写入当前档案。
          def initialize(values)
            @values = values
          end

          # 声明登录结束提示符。
          def login(pattern) = @values[:login_prompt] = pattern

          # 声明普通命令结束提示符。
          def command(pattern) = @values[:command_prompt] = pattern

          # 声明用户名输入提示。
          def username(pattern) = @values[:username_prompt] = pattern

          # 声明密码输入提示。
          def password(pattern) = @values[:password_prompt] = pattern

          # 声明特权模式提示符。
          def privilege(pattern) = @values[:privilege_prompt] = pattern
        end

        # 分页规则的声明对象。
        class Pager
          # 将分页模式和响应写入当前档案。
          def initialize(values)
            @values = values
          end

          # 声明分页提示匹配模式。
          def pattern(value) = @values[:pager_pattern] = value

          # 声明匹配分页提示后发送的字节。
          def response(value) = @values[:pager_response] = value
        end

        # 设备错误模式的声明对象。
        class Errors
          # 将错误模式列表写入当前档案。
          def initialize(values)
            @values = values
          end

          # 替换认证失败模式列表。
          def authentication(*patterns)
            @values[:authentication_error_patterns] = patterns.flatten
          end

          # 替换命令失败模式列表。
          def command(*patterns)
            @values[:command_error_patterns] = patterns.flatten
          end
        end

        # 登录和命令交互的声明对象。
        class Interactions
          attr_reader :login_interactions, :confirmation_interactions

          # 复制继承的交互规则，子类可以在其上追加设备差异。
          def initialize(values)
            @login_interactions = values[:login_interactions].dup
            @confirmation_interactions = values[:confirmation_interactions].dup
          end

          # 声明登录阶段的一次性应答。
          def login(pattern, response:, sensitive: false, limit: 1, capture: true)
            @login_interactions << Interaction.new(pattern, response, sensitive: sensitive,
                                                   limit: limit, capture: capture)
          end

          # 声明命令阶段的确认应答。
          def confirm(pattern, response:, sensitive: false, limit: nil, capture: true)
            @confirmation_interactions << Interaction.new(pattern, response, sensitive: sensitive,
                                                          limit: limit, capture: capture)
          end
        end

        # 特权认证规则的声明对象。
        class Privilege
          # 将特权命令和结束提示写入当前档案。
          def initialize(values)
            @values = values
          end

          # 声明进入特权模式的设备命令。
          def command(value) = @values[:privilege_command] = value

          # 声明特权命令完成后的提示符。
          def prompt(value) = @values[:privilege_prompt] = value
        end

        # SSH 兼容参数的声明对象。
        class Ssh
          # 将旧版 SSH 参数写入当前档案。
          def initialize(values)
            @values = values
          end

          # 声明连接旧版设备所需的参数序列。
          def legacy_arguments(*arguments) = @values[:legacy_ssh_arguments] = arguments.flatten
        end
      end
    end
  end
end
