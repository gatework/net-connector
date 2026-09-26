# frozen_string_literal: true

require_relative "../device/base"
require_relative "h3c/tftp_backup"
require_relative "h3c/topology"

module Net
  module Connector
    module H3c
      # H3C 直接使用登录后的命令视图，并在单个批次内解析设备分配的规则编号。
      class Connector < Net::Connector::Base
        vendor :h3c
        # 声明 H3C 的命令、提示、诊断和保存确认规则。
        profile do
          running_config_strategy Net::Connector::RunningConfig::Rendered
          tftp_strategy Net::Connector::H3c::TftpBackup
          topology_strategy Net::Connector::H3c::Topology
          commands do
            running_config "dis cur"
            save_config "save force"
          end

          prompts do
            login(/(?:\A|(?<=[\r\n]))(?:[^\S\n]|\x00)*\S+[>\]](?:[^\S\n]|\x00)*\z/)
            command(/(?:\A|(?<=[\r\n]))(?:[^\S\n]|\x00)*[^\r\n]+[>\]](?:[^\S\n]|\x00)*\z/)
            username(/(?:login|Username):\s*\z/i)
          end

          errors do
            command(
              /
                ^[ \t]*%[ \t]+(?:(?:Unrecognized|Ambiguous|Incomplete)\s+command|Too\s+many\s+parameters)
                \s+found\s+at\s+'\^'\s+position\.
              /ix,
              /^[ \t]*error:/i,
              /^[ \t]*Permission\s+denied\./i,
              /^\s*\^/
            )
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

        # 发送规则追加命令前，用本批次已获取的真实规则编号替换 XXX 占位符。
        def prepare_command(command, execution)
          return command unless /\A[ \t]*rule[ \t]+XXX[ \t]+append\b/i.match?(command.text)

          rule_id = execution.context[:rule_id]
          raise execution.failure("new rule ID has not been acquired") unless rule_id

          command.with_text(command.text.sub(/XXX/i, rule_id))
        end

        # 规则创建成功后查询当前配置，提取设备分配的编号并保存到本批次变量。
        def after_command(command, _response, execution)
          return unless /\A[ \t]*rule[ \t]+pass\b/i.match?(command.text)

          response = execution.query("dis this")
          rule_id = response.raw[/rule\s+(\d+)\s+pass[^\n]+\n\s*#/i, 1]
          raise execution.failure("device did not return the new rule ID") unless rule_id

          execution.context[:rule_id] = rule_id
        end
      end
    end
  end
end
