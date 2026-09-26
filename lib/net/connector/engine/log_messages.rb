# frozen_string_literal: true

module Net
  module Connector
    # 独立于日志目标的人类可读事件文案。
    module LogMessages
      module_function

      # 将结构化会话事件转换为便于人工阅读的中文日志。
      def format(name, fields)
        case name
        when "connect"
          "开始连接 #{fields[:host]}（#{fields[:protocol].to_s.upcase}，账号 #{fields[:username]}）"
        when "connect_failed"
          "连接失败：#{fields[:message]}（#{fields[:error]}）"
        when "login_start"
          "等待设备登录提示"
        when "login_output"
          "登录过程回显（已脱敏）："
        when "login_complete"
          fields[:status] == "ok" ? "登录成功，设备提示符：#{fields[:prompt]}" :
            "登录失败：#{fields[:message]}（#{fields[:error]}）"
        when "command_start"
          "下发命令：#{fields[:text]}"
        when "device_output"
          "设备回显："
        when "command_complete"
          fields[:status] == "response_received" ? "命令回显结束，已收到设备提示符" :
            "命令执行失败：#{fields[:message]}（#{fields[:error]}）"
        when "command_detail"
          "命令耗时 #{fields[:duration_ms]} 毫秒，收到 #{fields[:response_bytes]} 字节回显"
        when "tftp_backup"
          case fields[:status]
          when "reported_uploaded"
            "TFTP 备份：设备报告上传成功，目标 #{fields[:server]}/#{fields[:path]}；服务器文件尚未核验"
          when "transfer_failed"
            "TFTP 备份失败：设备报告传输失败，服务器 #{fields[:server]}"
          else
            "TFTP 备份未确认：设备未报告上传成功，服务器 #{fields[:server]}"
          end
        else
          name.to_s
        end
      end
    end
  end
end
