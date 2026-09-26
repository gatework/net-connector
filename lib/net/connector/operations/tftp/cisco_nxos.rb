# frozen_string_literal: true

require_relative "../../vendor/cisco_nxos/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::CiscoNxos = Net::Connector::CiscoNxos::TftpBackup
    end
  end
end
