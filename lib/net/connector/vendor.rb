# frozen_string_literal: true

module Net
  module Connector
    # 平台注册表只保存名称；选择平台时才加载对应连接器和策略。
    module Vendor
      REGISTRY = {
        h3c: "H3c", h3c_wireless: "H3cWireless", cisco_ios: "CiscoIos", cisco_nxos: "CiscoNxos",
        radware: "Radware", palo_alto: "PaloAlto", huawei: "Huawei", hillstone: "Hillstone",
        topsec: "Topsec", fortinet: "Fortinet", juniper: "Juniper"
      }.freeze
      private_constant :REGISTRY

      def self.keys = REGISTRY.keys

      def self.fetch(vendor)
        key = vendor.to_s.downcase.tr(" -", "__").to_sym
        name = REGISTRY.fetch(key) { raise ArgumentError, "unsupported vendor: #{vendor.inspect}" }
        require_relative "vendor/#{key}"
        const_get(name, false)
      end
    end
  end
end
