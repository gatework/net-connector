# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class InterfaceDescriptionTest < Minitest::Test
  Neighbor = Struct.new(:neighbor_name, :neighbor_interface)
  Names = Net::Connector::Topology::InterfaceName
  Descriptions = Net::Connector::Topology::InterfaceDescription

  def test_abbreviations_preserve_case_numbering_and_unknown_formats
    {
      "ethernet1/1" => "eth1/1", "Ethernet1/1" => "Eth1/1", "ETHERNET1/1" => "ETH1/1",
      "GigabitEthernet1/0/24.100" => "Gi1/0/24.100", "gigabitethernet1/0/24" => "gi1/0/24",
      "Ten-GigabitEthernet1/0/2" => "Te1/0/2", "TenGigabitEthernet1/0/2" => "Te1/0/2",
      "XGE1/0/2" => "TE1/0/2", "GE1/0/2" => "GI1/0/2", "FastEthernet0/1" => "Fa0/1",
      "port-channel12" => "po12", "Port-Channel12" => "Po12", "Gi1/0/2" => "Gi1/0/2",
      "ge-0/0/1" => "ge-0/0/1", "Port 12" => "Port 12", "100GE1/0/1" => "100GE1/0/1"
    }.each do |original, expected|
      assert_equal expected, Names.short(original), original
      assert_equal expected, Names.short(expected), "abbreviation must be stable: #{original}"
      assert_equal expected.downcase, Names.short(original, lowercase: true)
    end
    refute_equal Names.key("GigabitEthernet1/1"), Names.key("TenGigabitEthernet1/1")
    refute_equal Names.key("Eth1/1.10"), Names.key("Eth1/1.20")
  end

  def test_common_formatter_has_independent_abbreviation_and_case_options
    neighbor = Neighbor.new("Core-SW", "Ethernet1/2")
    assert_equal "To Core-SW Eth1/2", Descriptions.format(neighbor)
    assert_equal "To Core-SW eth1/2", Descriptions.format(neighbor, lowercase: true)
    assert_equal "To Core-SW Ethernet1/2", Descriptions.format(neighbor, abbreviate: false)
    assert_equal "To Core-SW ethernet1/2", Descriptions.format(neighbor, abbreviate: false, lowercase: true)
    assert_equal "Ethernet1/2", neighbor.neighbor_interface
    assert_equal "Core-SW", neighbor.neighbor_name
  end

  def test_common_command_builder_uses_the_supplied_local_interface_spelling
    assert_equal ["interface Ethernet1/1", "description To Core-SW Eth1/2", "exit"],
                 Descriptions.commands(interface: "Ethernet1/1", description: "To Core-SW Eth1/2")
    assert_equal ["interface Ten-GigabitEthernet1/0/1", "description To Core-SW Gi1/2", "quit"],
                 Descriptions.commands(interface: "Ten-GigabitEthernet1/0/1", description: "To Core-SW Gi1/2", leave: "quit")
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
