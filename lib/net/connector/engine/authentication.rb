# frozen_string_literal: true

require_relative "dialogue"

module Net
  module Connector
    # 密码或密钥登录与显式特权认证共用有界对话流程。
    class Authentication
      CONNECTION_FAILURES = {
        /REMOTE HOST IDEN|IDENTIFICATION CHANGED/i => [ConnectionError, :host_key_changed],
        /Host key verification failed/i => [ConnectionError, :host_key_untrusted],
        /RSA modulus too small/i => [ConnectionError, :rsa_too_small],
        /Selected cipher type <unknown> not supported by server/i => [ConnectionError, :unsupported_cipher],
        /Connection refused/i => [ConnectionError, :connection_refused],
        /No route to host/i => [ConnectionError, :no_route],
        /Connection reset/i => [ConnectionError, :connection_reset],
        /(?:Operation|Connection) timed out/i => [ConnectionError, :connection_timeout]
      }.freeze
      SSH_CONFIRMATION = %r{\(yes/no(?:/\[fingerprint\])?\)\?\s*\z}i

      # 保存会话配置，并合并传输失败和设备认证失败模式。
      def initialize(session, dialogue)
        @session = session
        @dialogue = dialogue
        @config = session.configuration
        @failures = CONNECTION_FAILURES.merge(
          dialogue.authentication_errors.to_h { |pattern| [pattern, [AuthenticationError, :authentication_failed]] }
        ).freeze
      end

      # 在登录提示或连接失败模式出现前读取登录响应。
      def login
        @session.reader.read(
          prompt: @dialogue.login_prompt, interactions: login_interactions, failures: @failures,
          timeout: @config.login_timeout, phase: :login
        )
      end

      # 发送特权命令，并在截止时间内完成凭据交互。
      def enable(command, prompt)
        deadline = Expect.monotonic + @config.login_timeout
        @session.write("#{command}\n", deadline: deadline, phase: :enable)
        secret = @config.enable_password || @config.password
        @session.reader.read(prompt: prompt, interactions: credential_interactions(secret), failures: @failures,
                             deadline: deadline, phase: :enable)
      end

      private

      # 为用户名和密码创建一次性敏感交互规则。
      def credential_interactions(secret)
        [
          Interaction.new(@dialogue.username_prompt, ->(_prompt) { input_line(@config.username) },
                          sensitive: true, limit: 1, capture: false),
          Interaction.new(@dialogue.password_prompt, ->(_prompt) { input_line(secret) },
                          sensitive: true, limit: 1, capture: false)
        ]
      end

      # 组装主机密钥确认、厂商挑战和凭据交互。
      def login_interactions
        host_key = Interaction.new(SSH_CONFIRMATION, lambda { |_prompt|
          if @config.host_key_policy == :strict
            raise @session.build_error(ConnectionError, "host key confirmation rejected",
                                 phase: :login, code: :host_key_untrusted), cause: nil
          end
          "yes\n"
        }, limit: 1)
        [host_key, *@dialogue.login_interactions, *@config.challenges.map(&:challenge),
         *credential_interactions(@config.password)]
      end

      # 将可选凭据编码为带换行的设备输入。
      def input_line(secret) = secret && "#{secret}\n"
    end
  end
end
