# frozen_string_literal: true

require_relative "tftp_archive"

module Net
  module Connector
    module Netdisco
      # Compatibility with the first batch archive entry point.
      class TftpHistory < TftpArchive
        def initialize(server:, **options) # rubocop:disable Lint/UnusedMethodArgument -- Accept the former constructor keyword.
          super(**options)
        end
      end
    end
  end
end
