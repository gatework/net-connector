# frozen_string_literal: true

module Net
  module Connector
    # 只选择一次连接级恢复；任何设备命令都不会重放。
    class Recovery
      # 只有明确允许的 SSH 拒绝才会建立一次 Telnet 连接。
      class TelnetFallback
        # 将连接被拒绝转换为 Telnet 传输，否则不提供恢复。
        def recover(error, transport)
          transport.as_telnet if error.code == :connection_refused && transport.respond_to?(:as_telnet)
        end
      end

      # 主机密钥替换仅限调用方指定的 known_hosts 文件。
      class HostKeyReplacement
        # 删除旧密钥并返回原传输对象，其他错误不触发替换。
        def recover(error, transport)
          return unless error.code == :host_key_changed && transport.respond_to?(:replace_host_key)

          transport.replace_host_key
          transport
        end
      end

      # 旧版协商参数来自厂商配置，不能由设备输出决定。
      class LegacySsh
        # 保存厂商提供的旧版参数。
        def initialize(arguments)
          @arguments = arguments
        end

        # 根据明确错误码创建一次旧版 SSH 传输。
        def recover(error, transport)
          return unless transport.respond_to?(:with_legacy)

          arguments = { rsa_too_small: @arguments, unsupported_cipher: ["-c", "des"] }[error.code]
          transport.with_legacy(arguments) if arguments
        end
      end

      # 按配置顺序建立可用的连接级恢复规则。
      def initialize(configuration, legacy_arguments:)
        @rules = []
        @rules << TelnetFallback.new if configuration.telnet_fallback?
        @rules << HostKeyReplacement.new if configuration.host_key_policy == :replace
        @rules << LegacySsh.new(legacy_arguments) if configuration.legacy_ssh?
        @rules.freeze
      end

      # 依次尝试恢复规则，并只返回第一个新传输对象。
      def recover(error, transport)
        @rules.lazy.filter_map { |rule| rule.recover(error, transport) }.first
      end
    end
  end
end
