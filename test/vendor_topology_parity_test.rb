# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class VendorTopologyParityTest < Minitest::Test
  def teardown = @device&.close

  def test_huawei_lldp_keeps_spaced_and_compact_interface_names
    build(:huawei, <<~TEXT)
      Local Intf              Neighbor Dev   Neighbor Intf              Exptime (sec)
      ------------------------------------------------------------------------------
      Gigabitethernet 0/1/0    peer-a         Gigabitethernet 0/1/1      101
      XGE1/0/5                peer-b         XGE1/0/18                  111
    TEXT
    rows = @device.interfaces.neighbors
    assert_equal ["Gigabitethernet 0/1/0", "XGE1/0/5"], rows.map(&:local_interface)
    assert_equal ["Gigabitethernet 0/1/1", "XGE1/0/18"], rows.map(&:neighbor_interface)
    assert(rows.all? { |neighbor| neighbor.protocol == :lldp && neighbor.chassis_id.empty? })
    assert_equal ["display lldp neighbor brief\n"], @transport.writes
  end

  def test_huawei_empty_header_is_distinct_from_missing_or_partial_output
    build(:huawei, "Local Intf   Neighbor Dev   Neighbor Intf   Exptime(s)\n---\n")
    assert_empty @device.interfaces.neighbors
    ["", "Unknown output\n", "Local Intf   Neighbor Dev   Neighbor Intf   Exptime(s)\nGE1/0/1 peer\n"].each do |text|
      @device.close
      build(:huawei, text)
      assert_raises(Net::Connector::ParsingError) { @device.interfaces.neighbors }
    end
  end

  def test_huawei_reads_descriptions_and_preserves_interface_identity
    build(:huawei, "interface GigabitEthernet 0/1/0\n description uplink core\n#\ninterface XGigabitEthernet1/0/5\n#\nreturn\n")
    assert_equal({ "gigabitethernet0/1/0" => "uplink core", "tengigabitethernet1/0/5" => "" }, @device.interfaces.descriptions)
    assert @device.supports?(:neighbors)
    assert @device.supports?(:interface_descriptions)
    refute @device.supports?(:interface_description_changes)
  end

  def test_huawei_does_not_accept_silently_dropped_interface_blocks
    build(:huawei, "interface GigabitEthernet1/0/1 invalid\n description partial\n#\n")
    assert_raises(Net::Connector::ParsingError) { @device.interfaces.descriptions }
  end

  def test_fortios_reads_descriptions_without_alias_or_nested_table_leakage
    build(:fortinet, <<~TEXT)
      config system interface
          edit "port1"
              set alias "alias is not description"
              set description "uplink core"
              config ipv6
                  config ip6-extra-addr
                      edit "2001:db8::1/64"
                          set description "nested is not interface description"
                      next
                  end
              end
          next
          edit "port2"
              set description ""
          next
      end
      config firewall address
          edit "unrelated"
              set description "not an interface"
          next
      end
    TEXT
    assert_equal({ "port1" => "uplink core", "port2" => "" }, @device.interfaces.descriptions)
    assert_equal ["show full-configuration\n"], @transport.writes
  end

  def test_fortios_rejects_incomplete_and_ambiguous_scopes
    ["config system interface\n    edit port1\n        set description partial\nend\n",
     "config system interface\n    edit port1\n        set description \"partial\n    next\nend\n",
     "config global\n    config system interface\n        edit port1\n        next\n    end\nend\n",
     "config system interface\nend\nconfig system interface\nend\n"].each do |config|
      @device&.close
      build(:fortinet, config)
      assert_raises(Net::Connector::ParsingError) { @device.interfaces.descriptions }
    end
  end

  def test_junos_keeps_logical_and_physical_descriptions_separate
    build(:juniper, <<~TEXT)
      set interfaces ge-0/0/0 description "physical uplink"
      set interfaces ge-0/0/0 unit 0 description "customer VLAN"
      set interfaces ge-0/0/0 unit 0 family inet address 192.0.2.1/24
      set interfaces ge-0/0/0 unit 100 description "another VLAN"
    TEXT
    assert_equal({ "ge-0/0/0" => "physical uplink", "ge-0/0/0.0" => "customer VLAN", "ge-0/0/0.100" => "another VLAN" },
                 @device.interfaces.descriptions)
  end

  def test_junos_missing_description_value_is_not_an_empty_description
    ["set interfaces ge-0/0/0 description\n", "set interfaces ge-0/0/0 unit 100 description\n"].each do |config|
      @device&.close
      build(:juniper, config)
      assert_raises(Net::Connector::ParsingError) { @device.interfaces.descriptions }
    end
  end

  def test_missing_interface_description_values_are_rejected_across_dialects
    samples = {
      cisco_ios: "interface Ethernet1\n description\n!\n",
      cisco_nxos: "interface Ethernet1\n description\n\n",
      h3c: "interface Ethernet1\n description\n#\n",
      huawei: "interface Ethernet1\n description\n#\n",
      hillstone: "interface ethernet0/1\n description\nexit\n",
      fortinet: "config system interface\n    edit port1\n        set description\n    next\nend\n",
      palo_alto: "set network interface ethernet ethernet1/1 comment\n",
      radware: "/cfg/port 1\n  name\n"
    }
    samples.each do |vendor, config|
      context = Struct.new(:profile, :host, :vendor, :config) do
        def running_config = Net::Connector::Result.new(config: config)
      end.new(Net::Connector.vendor_class(vendor).profile, "192.0.2.1", vendor, config)
      topology = Net::Connector::Interfaces.new(context)
      assert_raises(Net::Connector::ParsingError, vendor.to_s) { topology.descriptions }
      context.config = config.sub(/(description|comment|name)\n/) { "#{Regexp.last_match(1)} \"\"\n" }
      assert_equal [""], topology.descriptions.values, vendor.to_s
    end
  end

  def test_radware_port_names_decode_quotes_and_reject_incomplete_values
    context = Struct.new(:profile, :host, :vendor, :config) do
      def running_config = Net::Connector::Result.new(config: config)
    end.new(Net::Connector.vendor_class(:radware).profile, "192.0.2.1", :radware,
            %q(/cfg/port 1/name "uplink \"core\"") + "\n")
    topology = Net::Connector::Interfaces.new(context)
    assert_equal({ "1" => 'uplink "core"' }, topology.descriptions)
    ["/cfg/port 2/name\n", "/cfg/port 1\n  name valid\n/cfg/port 2/name\n"].each do |config|
      context.config = config
      assert_raises(Net::Connector::ParsingError) { topology.descriptions }
    end
    context.config = "/cfg/port 1\n  name \"truncated-private-marker\n"
    error = assert_raises(Net::Connector::ParsingError) { topology.descriptions }
    assert_equal :unrecognized_output, error.code
    assert_nil error.cause
    refute_includes error.full_message, "truncated-private-marker"
  end

  private

  def build(vendor, output)
    prompt = { huawei: "[router]", fortinet: "FGT # ", juniper: "audit@ex01> " }.fetch(vendor)
    @transport = ConnectorFake.new(prompt, "#{output}#{prompt}")
    @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: @transport)
  end
end
