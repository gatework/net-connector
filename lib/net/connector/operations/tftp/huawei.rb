# frozen_string_literal: true

require_relative "../../vendor/huawei/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::Huawei = Net::Connector::Huawei::TftpBackup
    end
  end
end
