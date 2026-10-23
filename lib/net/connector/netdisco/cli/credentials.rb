# frozen_string_literal: true

require "json"

# 命令行凭据来源；业务入口负责规划和执行备份。
module Net
  module Connector
    module Netdisco
      class CLI
        # 将调用方提供的输入解析为清单来源和设备凭据 resolver。
        module Credentials
          # 解析环境或标准输入凭据，返回清单来源与逐设备凭据回调。
          def self.resolve(settings, stdin_credentials: false, input: $stdin)
            unless stdin_credentials
              return [settings.inventory, settings.method(:device_credentials_for)]
            end

            begin
              values = JSON.parse(input.gets("\n") || "")
            rescue JSON::ParserError
              raise ArgumentError, "Invalid credentials JSON", cause: nil
            end
            keys = %w[netdisco_username netdisco_password device_username device_password]
            raise ArgumentError, "Four nonempty credential strings are required" unless values.is_a?(Hash) && keys.all? { |key| values[key].is_a?(String) && !values[key].strip.empty? }

            inventory = settings.inventory(credentials: {
              username: values.fetch("netdisco_username"), password: values.fetch("netdisco_password")
            })
            credentials = lambda do |device|
              inherited = device ? settings.device_credentials_for(device) : nil
              (inherited || {}).merge(username: values.fetch("device_username"),
                                     password: values.fetch("device_password"))
            end
            [inventory, credentials]
          end
        end
      end
    end
  end
end
