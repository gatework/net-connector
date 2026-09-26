# frozen_string_literal: true

require_relative "../device/base"
require_relative "radware/tftp_backup"
require_relative "radware/topology"

module Net
  module Connector
    module Radware
      # Radware Alteon 和 DefensePro 命令行配置采集连接器。
      class Connector < Net::Connector::Base
        vendor :radware
        # 声明菜单式 CLI 的命令、提示、超时、诊断和确认规则。
        profile do
          running_config_strategy Net::Connector::RunningConfig::Rendered
          tftp_strategy Net::Connector::Radware::TftpBackup
          topology_strategy Net::Connector::Radware::Topology
          commands do
            running_config "/cfg/dump"
            save_config "/cfg/save"
          end

          prompts do
            login(/(?:\A|(?<=[\r\n]))(?:>>[^\r\n]*|[^\r\n]+[>#])\s*\z/)
            command(/(?:\A|(?<=[\r\n]))(?:>>[^\r\n]*|[^\r\n]+#)\s*\z/)
          end

          errors do
            command(/^[ \t]*(?:Unknown|Invalid|Error)\s+command\b/i)
          end

          command_timeout 30

          interactions do
            confirm %r{Confirm\s+Sync\s+to\s+Peer\s+\[y/n\]:\s*\z}i, response: "y\n"
            confirm %r{Synchronize\s+configuration\s+changes\?\s+\[y/n\]:\s*\z}i, response: "y\n"
            confirm %r{Confirm\s+saving\s+to\s+FLASH\s+\[y/n\]:\s*\z}i, response: "y\n"
            confirm %r{Confirm\s+operation\s+without\s+applying\s+changes\s+
              \(leave\s+them\s+pending\)\s+\[y/n\]:\s*\z}ix, response: "y\n"
            confirm %r{Confirm\s+operation\s+without\s+saving\s+changes\s+
              \(leave\s+them\s+pending\)\s+\[y/n\]:?\s*\z}ix, response: "y\n"
            confirm(/Confirm\s+seeing\s+above\s+note\s+\[y\]:\s*\z/i, response: "y\n")
            confirm(/Please\s+enter\s+y\s+to\s+perform\s+the\s+action,\s+n\s+to\s+skip\s+it:\s*\z/i,
                    response: "y\n"
            )
            confirm %r{Display\s+private\s+keys\?\s+\[y/n\]:\s*\z}i, response: "n\n"
          end
        end

        # 连接有效期间返回登录横幅中的 HA 状态。
        def ha_state = connected? ? @ha_state : nil

        protected

        # 从登录横幅提取 HA 状态并冻结，供连接期间查询。
        def after_login(_session, response)
          @ha_state = response.raw[/^\s*HA\s+State:\s*(\S+)/i, 1]&.freeze
        end
      end
    end
  end
end
