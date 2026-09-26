# frozen_string_literal: true

require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module Hillstone
      class RunningConfig < Net::Connector::RunningConfig::Strategy
        def clean(text) = text.gsub(/\x00?\x08+[ \t]+\x08+/, "")
      end
    end
  end
end
