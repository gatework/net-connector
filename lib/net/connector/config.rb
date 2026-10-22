# frozen_string_literal: true

require "ctx_cli/configuration"

module Net
  module Connector
    # 保留原配置入口和路径政策；通用发现、来源与快照由 ctx_cli 维护。
    class Config < CtxCli::Configuration
      NAMES = %w[vxlan wireless backup topology].freeze
      COMMON_KEYS = %w[netdisco inventory ssh].freeze
      CONFIG_ENV = { "vxlan" => "VXLAN_CONFIG", "wireless" => "WIRELESS_CONFIG",
                     "backup" => "NC_CONFIG", "topology" => "NC_CONFIG" }.freeze

      def initialize(name:, config_env: nil, **options)
        name = name.to_s
        raise ArgumentError, "unsupported configuration name: #{name}" unless NAMES.include?(name)

        super(name: name, config_env: config_env || CONFIG_ENV.fetch(name), namespace: "net-connector",
              names: NAMES, common_keys: COMMON_KEYS, **options)
      end

      # 共享文件按工具分区；各专用 YAML 保持原有字段布局。
      def self.dump(document, name:, path:)
        raise ArgumentError, "unsupported configuration name: #{name}" unless NAMES.include?(name.to_s)

        super(document, name: name, path: path, namespace: "net-connector")
      end
    end
  end
end
