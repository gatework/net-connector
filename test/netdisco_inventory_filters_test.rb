# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"

class NetdiscoInventoryFiltersTest < Minitest::Test
  N = Net::Connector::Netdisco

  def row(ip: "192.0.2.10", name: "SZX11-Core", vendor: "H3C")
    { "ip" => ip, "name" => name, "vendor" => vendor }
  end

  def test_address_ranges_match_inventory_without_expansion_and_exclusion_wins
    rules = N::Rules.new(include_hosts: ["192.0.2.1-20", "2001:db8::/32"], exclude_hosts: ["192.0.2.10-192.0.2.12"])
    assert N::Device.from_row(row(ip: "192.0.2.1"), rules: rules).ready?
    assert N::Device.from_row(row(ip: "192.0.2.20"), rules: rules).ready?
    assert_equal :filtered, N::Device.from_row(row(ip: "192.0.2.21"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row, rules: rules).issue
    assert N::Device.from_row(row(ip: "2001:db8:ffff:ffff::1"), rules: rules).ready?
    refute N::Device.from_row(row(ip: "2001:db9::1"), rules: rules).ready?
  end

  def test_name_and_vendor_filters_intersect_with_address_filters
    rules = N::Rules.new(include_hosts: ["192.0.2.0/24"], include_names: ["szx11"], exclude_names: ["wlc"],
                         include_vendors: [:h3c], exclude_vendors: [:huawei])
    assert N::Device.from_row(row, rules: rules).ready?
    assert_equal :filtered, N::Device.from_row(row(name: "SZX11-WLC"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(ip: "192.0.3.1"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(name: "SZX12-Core"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(vendor: "Huawei"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(name: nil), rules: rules).issue
  end

  def test_explicit_filter_can_exclude_an_unknown_vendor_without_hiding_selected_unknown_devices
    rules = N::Rules.new(include_names: ["szx11"])
    excluded = N::Device.from_row(row(name: "SZX12-Other", vendor: "Unknown Appliance"), rules: rules)
    selected = N::Device.from_row(row(vendor: "Unknown Appliance"), rules: rules)
    assert_equal :filtered, excluded.issue
    assert_equal :unsupported_vendor, selected.issue
  end

  def test_name_modes_and_dns_fallback_are_literal_and_case_insensitive
    %w[contains prefix glob].each do |mode|
      pattern = mode == "glob" ? "SZX11-*" : "SZX11"
      rules = N::Rules.new(include_names: [pattern], name_match: mode)
      assert N::Device.from_row(row(name: nil).merge("dns" => "szx11-core"), rules: rules).ready?
      refute N::Device.from_row(row(name: "x-szx11-core"), rules: rules).ready? unless mode == "contains"
    end
    rules = N::Rules.new(include_names: ["[CORE]"], name_match: :contains)
    assert N::Device.from_row(row(name: "szx11-[Core]"), rules: rules).ready?
    refute N::Device.from_row(row(name: "szx11-c"), rules: rules).ready?
  end

  def test_invalid_ranges_and_filter_values_are_rejected_without_parser_causes
    ["192.0.2.20-1", "192.0.2.1-256", "192.0.2.1-2001:db8::1", "bad", "2001:db8::/129"].each do |value|
      error = assert_raises(ArgumentError) { N::Rules.new(include_hosts: [value]) }
      assert_nil error.cause
    end
    assert_raises(ArgumentError) { N::Rules.new(name_match: "regex") }
    assert_raises(ArgumentError) { N::Rules.new(include_names: [""]) }
    assert_raises(ArgumentError) { N::Rules.new(exclude_vendors: [:unknown]) }
  end
end
