# frozen_string_literal: true

module Net
  module Connector
    # 设备凭据的字段优先级；借用来源，每次解析独立快照，不缓存秘密。
    class Credentials
      def initialize(env: ENV)
        raise ArgumentError, "Credential source must support key lookup" unless env.respond_to?(:[])
        @env = env
      end

      # 平台字段优先于通用字段；缺少用户名时由宿主决定跳过或拒绝。
      def resolve(platform:)
        unless (platform.is_a?(String) || platform.is_a?(Symbol)) && /\A[a-z][a-z0-9_]*\z/i.match?(platform.to_s)
          raise ArgumentError, "Credential platform must be a name"
        end
        prefix = "NC_#{platform.to_s.upcase}_"
        username = value(prefix + "USERNAME") || value("NC_DEVICE_USERNAME")
        return nil unless username

        { username: username, password: value(prefix + "PASSWORD") || value("NC_DEVICE_PASSWORD"),
          enable_password: value(prefix + "ENABLE_PASSWORD") || value("NC_ENABLE_PASSWORD") }.freeze
      end

      def inspect = "#<#{self.class}>"
      alias to_s inspect
      def pretty_print(printer) = printer.text(inspect)

      private

      # 拒绝非法值而不回显内容，也不冻结调用方的字符串。
      def value(key)
        result = @env[key]
        raise ArgumentError, "#{key} must be a String" unless result.nil? || result.is_a?(String)
        result.dup.freeze unless result.nil? || result.strip.empty?
      end
    end
  end
end
