# frozen_string_literal: true

require_relative "../device/base"
require_relative "juniper/topology"
require_relative "juniper/remote_backup"

module Net
  module Connector
    module Vendor
      # Junos 操作视图采集已提交配置；不进入候选视图，也不执行隐式 commit。
      class Juniper < Net::Connector::Base
        vendor :juniper
        profile do
          running_config_strategy Net::Connector::RunningConfig::Rendered
          topology_strategy Topology
          remote_backup_strategy RemoteBackup
          commands { running_config "show configuration | display set | no-more" }
          prompts do
            login(/(?:\A|(?<=[\r\n]))[^\s@]+@[^\s>#]+>[ \t]*\z/)
            command(/(?:\A|(?<=[\r\n]))[^\s@]+@[^\s>#]+>[ \t]*\z/)
          end
          pager { pattern(/(?:\A|(?<=[\r\n]))[ \t]*---\(more(?: \d+%)?\)---[ \t]*\z/i) }
          errors do
            command(/^[ \t]*(?:error:|syntax error[,.]|unknown command\b|permission denied\b|(?:ftp|scp|ssh):\s)/i)
          end
          command_timeout 120
        end
      end
    end
  end
end
