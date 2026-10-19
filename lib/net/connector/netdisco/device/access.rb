# frozen_string_literal: true

require_relative "../device"

module Net
  module Connector
    module Netdisco
      class Device
        # 逐设备解析接入凭据与批次策略；不创建连接或缓存秘密。
        # @api private
        module Access
          # 逐设备读取凭据并合并固定连接策略和日志位置，不创建会话。
          def self.resolve(device, settings:, credentials:, policy:, log_directory:)
            options = credentials ? credentials.call(device) : settings.device_credentials_for(device)
            return nil if options.nil?

            unless options.is_a?(Hash) && options.keys.all?(Symbol) && !options.key?(:host) &&
                   options[:username].is_a?(String) && !options[:username].empty?
              raise ArgumentError, "credential resolver must return settings with username and without host"
            end

            options = policy.connection_options(device.vendor).merge(options)
            if log_directory
              options[:log_file] = File.join(log_directory, "#{device.host.tr(":", "_")}.log")
            end
            options
          end
        end
      end
    end
  end
end
