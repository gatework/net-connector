# frozen_string_literal: true

require "logger"

module Net
  module Connector
    class Log
      # 只安装在连接器自有的 Logger 上；注入的日志器保留应用自己的格式。
      class Formatter < ::Logger::Formatter
        def call(severity, time, _program, message)
          "[#{time.getlocal.strftime("%Y-%m-%d %H:%M:%S.%L %:z")}] #{severity} #{message}\n"
        end
      end
    end
  end
end
