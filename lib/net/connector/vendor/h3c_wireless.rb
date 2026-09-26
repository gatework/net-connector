# frozen_string_literal: true

require_relative "h3c"

module Net
  module Connector
    module H3cWireless
      # H3C 无线控制器沿用 Comware CLI，对无线设备单独暴露厂商入口。
      class Connector < H3c::Connector
        vendor :h3c_wireless
      end
    end
  end
end
