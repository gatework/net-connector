# frozen_string_literal: true

require_relative "../../vendor/cisco_ios/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::CiscoIos = Net::Connector::CiscoIos::TftpBackup
    end
  end
end
