# frozen_string_literal: true

require_relative "h3c"

module Net
  module Connector
    module Vendor
      # H3C 无线控制器沿用 Comware CLI，对无线设备单独暴露厂商入口。
      class H3cWireless < H3c
        vendor :h3c_wireless
      end
    end
  end
end
