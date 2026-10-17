# frozen_string_literal: true

require_relative "connector/version"
require_relative "connector/device/base"
require_relative "connector/vendor"

module Net
  # 设备 API 的公开加载入口；只登记厂商名称，实际连接器在首次选择时加载。
  module Connector
    # 返回当前支持的厂商标识集合。
    def self.vendors = Vendor.keys

    # 根据厂商标识查找连接器类。
    def self.vendor_class(vendor) = Vendor.fetch(vendor)

    # 根据厂商标识和连接参数创建设备对象。
    def self.build(vendor, **settings)
      vendor_class(vendor).new(**settings)
    end

    # 在代码块内连接设备并确保会话关闭。
    def self.open(vendor, **settings, &)
      raise ArgumentError, "open requires a block" unless block_given?

      vendor_class(vendor).open(**settings, &)
    end
  end
end
