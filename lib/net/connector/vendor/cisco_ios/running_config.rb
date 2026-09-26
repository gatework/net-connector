# frozen_string_literal: true

require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module CiscoIos
      class RunningConfig < Net::Connector::RunningConfig::Rendered
        def clean(text)
          config = super
          config.gsub!(/^[^\n]*#\s*terminal\s+length\s+0\s*\n/i, "")
          config.sub!(/^[^\n]*#\s*copy\s+run(?:ning-config)?\s+(?:start|startup-config)\s*\n.*\z/im, "")
          config.gsub!(/^!.*(?:Last\s+configuration\s+change|NVRAM\s+config).*\n/i, "")
          config
        end
      end
    end
  end
end
