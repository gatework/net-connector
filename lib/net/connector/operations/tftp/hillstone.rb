# frozen_string_literal: true

require_relative "../../vendor/hillstone/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::Hillstone = Net::Connector::Hillstone::TftpBackup
    end
  end
end
