# frozen_string_literal: true

require_relative "../device/base"
require_relative "huawei/tftp_backup"

module Net
  module Connector
    module Huawei
      # Huawei 命令行连接器；提权延迟到命令批次开始时执行。
      class Connector < Net::Connector::Base
        vendor :huawei
        # 声明 Huawei 的命令、提示、诊断、提权和保存确认规则。
        profile do
          running_config_strategy Net::Connector::RunningConfig::Rendered
          tftp_strategy Net::Connector::Huawei::TftpBackup
          commands do
            running_config "dis cur"
            save_config "save force"
          end

          prompts do
            login(/(?:\A|(?<=[\r\n]))\s*\S+[>\]]\s*\z/)
            command(/(?:\A|(?<=[\r\n]))[^\r\n]+[>\]]\s*\z/)
            username(/(?:login|Username):\s*\z/i)
          end

          errors do
            command(
              /^\s*\^/,
              /^[ \t]*error:/i,
              /^[ \t]*Permission\s+denied\./i,
              /
                ^[ \t]*%[ \t]+(?:(?:Unrecognized|Ambiguous|Incomplete)\s+command|Too\s+many\s+parameters)
                \s+found\s+at\s+'\^'\s+position\.
              /ix
            )
          end

          privilege do
            command "su"
            prompt(/privilege\s+(?:level\s+is|is\s+).+>\s*\z/im)
          end

          command_timeout 10

          interactions do
            confirm %r{Are\s+you\s+sure\?\s*\[Y/N\]}i, response: "y\n"
            confirm(/press\s+the\s+enter\s+key\)/i, response: "\n")
            confirm %r{Continue\?\s*\[Y/N\]}i, response: "y\n"
            confirm(/Please\s+input\s+the\s+file\s+name\(\*\.cfg\)\[[^\]]+\]\s*\z/i, response: "\n")
            confirm %r{overwrite\?\s*\[Y/N\]}i, response: "y\n"
          end
        end

        protected

        # 登录后若提示符以 ] 结尾，则确认设备已经处于特权视图。
        def after_login(session, response)
          session.mark_privileged! if response.prompt.include?("]")
        end
      end
    end
  end
end
