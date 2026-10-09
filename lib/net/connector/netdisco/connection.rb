# frozen_string_literal: true

require "json"

# 清单连接与设备凭据来源；业务入口负责规划和执行备份。
module Net
  module Connector
    module Netdisco
      # 将调用方提供的输入解析为清单客户端和设备凭据 resolver。
      class Connection
        def self.build(settings, stdin_credentials: false, input: $stdin)
          unless stdin_credentials
            return [settings.client, settings.method(:device_credentials_for)]
          end

          begin
            values = JSON.parse(input.gets || "")
          rescue JSON::ParserError
            raise ArgumentError, "凭据 JSON 无效", cause: nil
          end
          keys = %w[netdisco_username netdisco_password device_username device_password]
          raise ArgumentError, "需要四个非空凭据字符串" unless values.is_a?(Hash) && keys.all? { |key| values[key].is_a?(String) && !values[key].strip.empty? }

          client = settings.client(credentials: {
            username: values.fetch("netdisco_username"), password: values.fetch("netdisco_password")
          })
          credentials = lambda do |device|
            inherited = device ? settings.device_credentials_for(device) : nil
            (inherited || {}).merge(username: values.fetch("device_username"),
                                   password: values.fetch("device_password"))
          end
          [client, credentials]
        end
      end
    end
  end
end
