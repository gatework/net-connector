# frozen_string_literal: true

module Net
  module Connector
    class Log
      # 独立于日志目标的人类可读事件文案。
      module Messages
        module_function

        # 将结构化会话事件转换为便于人工阅读的中文日志。
        def format(name, fields)
          case name
          when "connect"
            "Connecting to #{fields[:host]}(#{fields[:protocol].to_s.upcase}, user #{fields[:username]})"
          when "connect_failed"
            "Connection failed: #{fields[:message]}(#{fields[:error]})"
          when "login_start"
            "Waiting for the device login prompt"
          when "login_output"
            "Login output (redacted): "
          when "login_complete"
            fields[:status] == "ok" ? "Login succeeded; device prompt: #{fields[:prompt]}" :
              "Login failed: #{fields[:message]}(#{fields[:error]})"
          when "command_start"
            "Sending command: #{fields[:text]}"
          when "device_output"
            "Device output: "
          when "command_complete"
            fields[:status] == "response_received" ? "Command output complete; device prompt received" :
              "Command failed: #{fields[:message]}(#{fields[:error]})"
          when "operation_start"
            "Starting device script"
          when "operation_complete"
            fields[:status] == "completed" ? "Device script complete" :
              "Device script failed: #{fields[:message]}(#{fields[:error]})"
          when "tftp_backup"
            case fields[:status]
            when "reported_uploaded"
              "TFTP backup: device reported a successful upload to #{fields[:server]}/#{fields[:path]}; server file has not been verified"
            when "transfer_failed"
              "TFTP backup failed: device reported a transfer failure; server #{fields[:server]}"
            else
              "TFTP backup unconfirmed: device did not report a successful upload; server #{fields[:server]}"
            end
          else
            name.to_s
          end
        end
      end
    end
  end
end
