# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"

class VendorDevicePolicyTest < Minitest::Test
  def policy(values)
    Net::Connector::Netdisco::VendorDevicePolicy.new(values, vendors: %i[cisco_nxos hillstone]) do |value|
      unless value.nil? || (value.is_a?(String) && value.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/))
        raise ArgumentError, "invalid VRF"
      end
    end
  end

  def test_device_override_vendor_default_and_explicit_protocol_default_are_distinct
    item = policy("cisco_nxos" => { "default" => "management", "hosts" => {
                    "192.0.2.1" => "production", "192.0.2.2" => nil } }, "hillstone" => "mgt-vr")
    assert_equal "production", item.for(vendor: :cisco_nxos, host: "192.0.2.1")
    assert_nil item.for(vendor: :cisco_nxos, host: "192.0.2.2")
    assert_equal "management", item.for(vendor: :cisco_nxos, host: "192.0.2.3")
    assert_equal "mgt-vr", item.for(vendor: :hillstone, host: "192.0.2.1")
    assert_nil item.for(vendor: :h3c, host: "192.0.2.1")
  end

  def test_ipv6_addresses_are_canonical_and_ambiguous_overrides_are_rejected
    item = policy(cisco_nxos: { default: "management", hosts: { "2001:db8::1" => "edge" } })
    assert_equal "edge", item.for(vendor: :cisco_nxos, host: "2001:0db8:0:0::1")
    assert_raises(ArgumentError) do
      policy(cisco_nxos: { hosts: { "2001:db8::1" => "a", "2001:0db8::1" => "b" } })
    end
  end

  def test_snapshots_do_not_retain_caller_owned_values
    value = String.new("management")
    data = { "cisco_nxos" => { "default" => value, "hosts" => { "192.0.2.1" => "edge" } } }
    item = policy(data)
    value.replace("other")
    data["cisco_nxos"]["hosts"].clear
    assert_equal "management", item.for(vendor: :cisco_nxos, host: "192.0.2.2")
    assert_equal "edge", item.for(vendor: :cisco_nxos, host: "192.0.2.1")
    assert item.for(vendor: :cisco_nxos, host: "192.0.2.1").frozen?
    assert item.to_h.frozen?
    assert_raises(FrozenError) { item.to_h[:cisco_nxos][:hosts].clear }
  end

  def test_every_declared_override_is_validated_before_selection
    [[], { unknown: "management" }, { cisco_nxos: { typo: "bad" } },
     { cisco_nxos: { hosts: [] } }, { cisco_nxos: { hosts: { "192.0.2.0/24" => "edge" } } },
     { cisco_nxos: { hosts: { "not-an-ip" => "edge" } } },
     { cisco_nxos: { default: "" } }, { cisco_nxos: { hosts: { "192.0.2.1" => "edge; command" } } }].each do |data|
      assert_raises(ArgumentError) { policy(data) }
    end
  end
end
