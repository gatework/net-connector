# frozen_string_literal: true

require_relative "../cisco_ios/running_config"

module Net
  module Connector
    module CiscoNxos
      class RunningConfig < CiscoIos::RunningConfig
        def clean(text)
          without_pager = text.to_s.gsub(
            /[ \t]*(?:\x1b\[[0-9;]*[A-Za-z])*--More--
              (?:\x1b\[[0-9;]*[A-Za-z])*(?:[\r\x00\x08 ]|\x1b\[[0-9;]*[A-Za-z])*/ix, ""
          )
          config = super(without_pager)
          config.sub!(/\A.*?^(?=[^\n]*#\s*show\s+running-config\s*$)/im, "")
          config.gsub(/^[ \t]*(?:\[[# ]*\]|\])[ \t]*\d+%[ \t]*\n?/i, "")
                .gsub(/^[ \t]*Copy\s+complete\b[^\n]*\n?/i, "")
        end
      end
    end
  end
end
