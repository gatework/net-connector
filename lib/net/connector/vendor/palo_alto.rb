# frozen_string_literal: true

require_relative "../device/base"
require_relative "palo_alto/running_config"
require_relative "palo_alto/tftp_backup"
require_relative "palo_alto/topology"

module Net
  module Connector
    module PaloAlto
      # Palo Alto Networks PAN-OS 运维命令行和运行配置采集连接器。
      class Connector < Net::Connector::Base
        vendor :palo_alto
        # 声明 PAN-OS 的命令、提示、超时、诊断和登录确认规则。
        profile do
          running_config_strategy Net::Connector::PaloAlto::RunningConfig
          tftp_strategy Net::Connector::PaloAlto::TftpBackup
          topology_strategy Net::Connector::PaloAlto::Topology
          commands do
            running_config "set cli pager off", "set cli config-output-format set", "show config diff",
                           "configure", "show", "exit", "show config diff"
          end

          prompts do
            login(/(?:\A|(?<=[\r\n]))(?:[^\s@]+)@[^\s>#]+[>#]\s*\z/)
            command(/(?:\A|(?<=[\r\n]))(?:[^\s@]+)@[^\s>#]+[>#]\s*\z/)
          end

          errors do
            command(/^[ \t]*(?:Invalid syntax|Unknown command|Server error|Command failed)(?:[.:]|\s)/i)
          end

          command_timeout 120

          interactions do
            login %r{(?:acknowledge|accept)[\s\S]*(?:yes/no|\[y/n\]|enter\s+yes)[^\r\n]*\z}i,
                  response: "yes\n"
          end
        end
      end
    end
  end
end
