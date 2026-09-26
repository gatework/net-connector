# frozen_string_literal: true

require_relative "../../vendor/palo_alto/tftp_backup"

module Net
  module Connector
    module Operations
      Tftp::PaloAlto = Net::Connector::PaloAlto::TftpBackup
    end
  end
end
