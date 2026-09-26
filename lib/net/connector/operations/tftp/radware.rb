# frozen_string_literal: true

require_relative "../../vendor/radware/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::Radware = Net::Connector::Radware::TftpBackup
    end
  end
end
