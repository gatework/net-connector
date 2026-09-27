# frozen_string_literal: true

require_relative "connector/version"
require_relative "connector/device/base"

module Net
  module Connector
    VENDORS = {
      h3c: "H3c",
      h3c_wireless: "H3cWireless",
      cisco_ios: "CiscoIos",
      cisco_nxos: "CiscoNxos",
      radware: "Radware",
      palo_alto: "PaloAlto",
      huawei: "Huawei",
      hillstone: "Hillstone"
    }.freeze

    # 返回当前支持的厂商标识集合。
    def self.vendors = VENDORS.keys

    # 根据厂商标识查找连接器类。
    def self.vendor_class(vendor)
      key = vendor.to_s.downcase.tr(" -", "__")
      key = key.to_sym
      name = VENDORS.fetch(key) { raise ArgumentError, "unsupported vendor: #{vendor.inspect}" }
      require_relative "connector/vendor/#{key}"
      const_get(name, false).const_get(:Connector, false)
    end

    # 根据厂商标识和连接参数创建设备对象。
    def self.build(vendor, **settings)
      vendor_class(vendor).new(**settings)
    end

    # 在代码块内连接设备并确保会话关闭。
    def self.open(vendor, **settings)
      raise ArgumentError, "open requires a block" unless block_given?

      vendor_class(vendor).open(**settings) { |device| yield device }
    end
  end
end
