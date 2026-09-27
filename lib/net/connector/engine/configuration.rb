# frozen_string_literal: true

require "expect/pty"
require_relative "dialogue"

module Net
  module Connector
    # 显式且不可变的连接设置；环境变量读取由调用库的可执行程序负责。
    class Configuration
      attr_reader :host, :username, :password, :enable_password, :protocol, :port, :login_timeout,
                  :command_timeout, :write_timeout, :max_output_bytes, :max_script_output_bytes, :log_file, :log_format, :log_level,
                  :known_hosts, :host_key_policy, :challenges, :logger

      # 校验端点、凭据、超时、日志、主机密钥和挑战配置，然后冻结设置。
      def initialize(host: nil, username: nil, password: nil, enable_password: nil, protocol: :ssh, port: nil,
                     login_timeout: 10, command_timeout: nil, write_timeout: 10,
                     max_output_bytes: 32 * 1024 * 1024, max_script_output_bytes: nil, log_file: nil, logger: nil,
                     log_format: :text, log_level: :info,
                     known_hosts: nil, host_key_policy: :strict, telnet_fallback: false, legacy_ssh: false,
                     challenges: [])
        @host = frozen_string(host)
        @username = frozen_string(username)
        @password = single_line_credential(password)
        @enable_password = single_line_credential(enable_password)
        @protocol = enum_value(protocol, %i[ssh telnet], :protocol)
        @port = port
        valid_port = port.nil? || (port.is_a?(Integer) && (1..65_535).cover?(port))
        unless valid_port
          raise ArgumentError, "port must be in 1..65535"
        end

        @login_timeout = timeout_seconds(login_timeout, :login_timeout)
        @command_timeout = command_timeout.nil? ? nil : timeout_seconds(command_timeout, :command_timeout)
        @write_timeout = timeout_seconds(write_timeout, :write_timeout)
        @max_output_bytes = positive_integer(max_output_bytes, :max_output_bytes)
        @max_script_output_bytes = positive_integer(max_script_output_bytes, :max_script_output_bytes) unless max_script_output_bytes.nil?
        @log_file = absolute_path(log_file)
        if logger && (!logger.respond_to?(:debug) || !logger.respond_to?(:info) ||
          !logger.respond_to?(:warn) || !logger.respond_to?(:error) ||
          !logger.respond_to?(:level))
          raise ArgumentError, "logger must be Logger-compatible"
        end
        raise ArgumentError, "logger and log_file cannot be combined" if logger && @log_file
        @log_format = enum_value(log_format, %i[raw text], :log_format)
        raise ArgumentError, "logger cannot be combined with raw logging" if logger && @log_format == :raw

        @logger = logger
        @log_level = enum_value(log_level, %i[debug info warn error], :log_level)
        @known_hosts = absolute_path(known_hosts)
        @host_key_policy = enum_value(host_key_policy, %i[strict accept_new replace], :host_key_policy)
        if @host_key_policy == :replace && !@known_hosts
          raise ArgumentError, "host_key_policy :replace requires an explicit known_hosts file"
        end

        @telnet_fallback = boolean_value(telnet_fallback)
        @legacy_ssh = boolean_value(legacy_ssh)
        unless challenges.is_a?(Array) && challenges.all?(Interaction)
          raise ArgumentError, "challenges must be an Array of Interaction objects"
        end

        @challenges = challenges.dup.freeze
        freeze
      end

      # 判断是否允许 SSH 失败后回退到 Telnet。
      def telnet_fallback? = @telnet_fallback

      # 判断是否允许使用旧版 SSH 协商参数恢复。
      def legacy_ssh? = @legacy_ssh

      # 校验最终连接主机和用户名能安全进入外部命令参数。
      def validate_endpoint!
        unless host.is_a?(String) && /\A[A-Za-z0-9:][A-Za-z0-9.:%_-]*\z/.match?(host)
          raise ArgumentError, "host must be a device address or hostname"
        end
        return if username.is_a?(String) && /\A[A-Za-z0-9_][A-Za-z0-9_.@$\\-]*\z/.match?(username)

        raise ArgumentError, "username is empty or contains unsupported characters"
      end

      # 返回不包含凭据的连接配置摘要。
      def inspect = "#<#{self.class} host=#{host.inspect} protocol=#{protocol.inspect}>"

      private

      def positive_integer(value, name)
        raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?

        value
      end

      # 将可选值校验为字符串副本。
      def frozen_string(value)
        return nil if value.nil?
        raise ArgumentError, "expected a String or nil" unless value.is_a?(String)

        value.dup.freeze
      end

      # 校验凭据是单行文本。
      def single_line_credential(value)
        value = frozen_string(value)
        raise ArgumentError, "credentials must be a single line" if value&.match?(/[\r\n\x00]/)

        value
      end

      # 将路径转换为绝对冻结文本。
      def absolute_path(value) = value.nil? ? nil : File.expand_path(frozen_string(value)).freeze

      # 将超时转换为有限秒数。
      def timeout_seconds(value, name)
        result = Expect.duration(value)
        raise ArgumentError, "#{name} must be finite" unless result

        result
      end

      # 校验布尔设置只能是 true 或 false。
      def boolean_value(value)
        raise ArgumentError, "expected true or false" unless [true, false].include?(value)

        value
      end

      # 将枚举输入转换为允许的符号。
      def enum_value(value, choices, name)
        return value.to_sym if value.respond_to?(:to_sym) && choices.include?(value.to_sym)

        raise ArgumentError, "#{name} must be one of #{choices.join(", ")}"
      end
    end
  end
end
