# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class InterfaceDescriptionTest < Minitest::Test
  Neighbor = Struct.new(:neighbor_name, :neighbor_interface)
  Names = Net::Connector::Interfaces::Name
  Descriptions = Net::Connector::Interfaces::Description

  def test_abbreviations_normalize_vendor_spelling_and_preserve_numbering
    {
      "ethernet1/1" => "Eth1/1", "Ethernet1/1" => "Eth1/1", "ETHERNET1/1" => "Eth1/1",
      "GigabitEthernet1/0/24.100" => "Gi1/0/24.100", "gigabitethernet1/0/24" => "Gi1/0/24",
      "Ten-GigabitEthernet1/0/2" => "Te1/0/2", "TenGigabitEthernet1/0/2" => "Te1/0/2",
      "XGE1/0/2" => "Te1/0/2", "GE1/0/2" => "Gi1/0/2", "FastEthernet0/1" => "Fa0/1",
      "port-channel12" => "Po12", "Port-Channel12" => "Po12", "Gi1/0/2" => "Gi1/0/2",
      "10GE1/0/2" => "Te1/0/2", "XGigabitEthernet1/0/2" => "Te1/0/2",
      "25GE1/0/1" => "Twe1/0/1", "TwentyFiveGigE1/0/1" => "Twe1/0/1",
      "40GE1/0/1" => "Fo1/0/1", "FortyGigabitEthernet1/0/1" => "Fo1/0/1",
      "HundredGigE1/0/1" => "Hu1/0/1", "ge-0/0/1" => "ge-0/0/1", "Port 12" => "Port 12", "100GE1/0/1" => "Hu1/0/1"
    }.each do |original, expected|
      assert_equal expected, Names.short(original), original
      assert_equal expected, Names.short(expected), "abbreviation must be stable: #{original}"
      assert_equal expected.downcase, Names.short(original, lowercase: true)
    end
    refute_equal Names.key("GigabitEthernet1/1"), Names.key("TenGigabitEthernet1/1")
    refute_equal Names.key("Eth1/1.10"), Names.key("Eth1/1.20")
  end

  def test_vendor_aggregation_and_high_speed_aliases_have_stable_distinct_names
    groups = {
      "Twe1/0/1:2.100" => %w[Twenty-FiveGigE1/0/1:2.100 WGE1/0/1:2.100 TwentyFiveGigE1/0/1:2.100],
      "Fo1/0/1" => %w[FortyGigE1/0/1 FGE1/0/1 FortyGigabitEthernet1/0/1],
      "Hu1/0/1" => %w[HundredGigE1/0/1 HGE1/0/1 HundredGigabitEthernet1/0/1],
      "Te0/1" => %w[xethernet0/1 xe0/1 TenGigE0/1 Ten-GigabitEthernet0/1],
      "BAGG25" => %w[Bridge-Aggregation25 BAGG25 bagg25],
      "RAGG25.100" => %w[Route-Aggregation25.100 RAGG25.100],
      "Po25" => %w[Port-channel25 port-channel25 Po25],
      "Agg25.100" => %w[aggregate25.100 Agg25.100]
    }
    groups.each do |expected, aliases|
      aliases.each do |name|
        assert_equal expected, Names.short(name), name
        assert_equal Names.key(aliases.first), Names.key(name), name
        assert_equal "To_peer_#{expected}", Descriptions.format(Neighbor.new("peer", name)), name
      end
      assert_equal expected, Names.short(expected)
    end
    refute_equal Names.key("BAGG25"), Names.key("RAGG25")
    refute_equal Names.key("WGE1/0/1"), Names.key("XGE1/0/1")
    refute_equal Names.key("FGE1/0/1"), Names.key("HGE1/0/1")
    refute_equal Names.key("WGE1/0/1:1"), Names.key("WGE1/0/1:2")
  end

  def test_common_formatter_has_independent_abbreviation_and_case_options
    neighbor = Neighbor.new("Core-SW", "Ethernet1/2")
    assert_equal "To_Core-SW_Eth1/2", Descriptions.format(neighbor)
    assert_equal "To_Core-SW_eth1/2", Descriptions.format(neighbor, lowercase: true)
    assert_equal "To_Core-SW_Ethernet1/2", Descriptions.format(neighbor, abbreviate: false)
    assert_equal "To_Core-SW_ethernet1/2", Descriptions.format(neighbor, abbreviate: false, lowercase: true)
    assert_equal "Ethernet1/2", neighbor.neighbor_interface
    assert_equal "Core-SW", neighbor.neighbor_name
  end

  def test_equivalent_cisco_huawei_and_h3c_peer_interfaces_share_the_same_default_description
    %w[GigabitEthernet1/0/1 GE1/0/1 gi1/0/1].each do |port|
      assert_equal "To_Core-SW_Gi1/0/1", Descriptions.format(Neighbor.new("Core-SW", port))
    end
    %w[TenGigabitEthernet1/0/1 Ten-GigabitEthernet1/0/1 XGigabitEthernet1/0/1 XGE1/0/1 10GE1/0/1].each do |port|
      assert_equal "To_Core-SW_Te1/0/1", Descriptions.format(Neighbor.new("Core-SW", port))
    end
    assert_equal "To_peer_Port_12", Descriptions.format(Neighbor.new("peer", "Port 12"))
    assert_equal "To_Core_SW_Eth1/1", Descriptions.format(Neighbor.new("Core SW", "ethernet1/1"))
  end

  def test_common_command_builder_uses_the_supplied_local_interface_spelling
    assert_equal ["interface Ethernet1/1", "description To_Core-SW_Eth1/2", "exit"],
                 Descriptions.commands(interface: "Ethernet1/1", description: "To_Core-SW_Eth1/2")
    assert_equal ["interface Ten-GigabitEthernet1/0/1", "description To_Core-SW_Gi1/2", "quit"],
                 Descriptions.commands(interface: "Ten-GigabitEthernet1/0/1", description: "To_Core-SW_Gi1/2", leave: "quit")
  end

  def test_public_formatter_and_builder_reject_unsafe_or_overlong_values
    ["peer;reload", "peer\nreload", "peer\"", "a" * 81].each do |name|
      assert_raises(ArgumentError) { Descriptions.format(Neighbor.new(name, "Ethernet1/1")) }
    end
    ["Gi1/1;reload", "Gi1/1\nshutdown"].each do |name|
      assert_raises(ArgumentError) { Descriptions.commands(interface: name, description: "uplink") }
    end
    assert_raises(ArgumentError) { Descriptions.commands(interface: "Gi1/1", description: "uplink;reload") }
    assert_raises(ArgumentError) { Descriptions.commands(interface: "Gi1/1", description: "uplink", leave: "reload") }
  end
end
