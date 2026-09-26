# frozen_string_literal: true

require_relative "../../vendor/h3c/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::H3c = Net::Connector::H3c::TftpBackup
    end
  end
end
