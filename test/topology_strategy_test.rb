# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "../lib/net/connector/vendor/cisco_ios/topology"
require_relative "../lib/net/connector/vendor/h3c/topology"
require_relative "../lib/net/connector/vendor/hillstone/topology"
require_relative "../lib/net/connector/vendor/palo_alto/topology"
require_relative "../lib/net/connector/vendor/radware/topology"
require_relative "support/fake_transport"

class TopologyStrategyTest < Minitest::Test
  Topology = Net::Connector::Topology

  def test_strategy_capabilities_are_static_and_inherited
    [Net::Connector::CiscoIos::Topology, Net::Connector::H3c::Topology, Net::Connector::Hillstone::Topology].each do |strategy|
      %i[neighbors interface_descriptions interface_description_changes].each do |capability|
        assert strategy.supports?(capability)
        assert Class.new(strategy).supports?(capability)
      end
      refute strategy.supports?(:unknown)
    end
    assert Net::Connector::PaloAlto::Topology.supports?(:neighbors)
    assert Net::Connector::PaloAlto::Topology.supports?(:interface_descriptions)
    refute Net::Connector::PaloAlto::Topology.supports?(:interface_description_changes)
    refute Class.new(Net::Connector::PaloAlto::Topology).supports?(:interface_description_changes)
    assert Net::Connector::Radware::Topology.supports?(:interface_descriptions)
    refute Net::Connector::Radware::Topology.supports?(:neighbors)
    refute Net::Connector::Radware::Topology.supports?(:interface_description_changes)
    refute Topology::Strategy.supports?(:neighbors)
    refute Topology::Strategy.supports?(:interface_descriptions)
    refute Topology::Strategy.supports?(:interface_description_changes)
  end

  def test_explicit_zero_neighbor_evidence_and_unrecognized_output
    samples = {
      Net::Connector::CiscoIos::Topology => "Total cdp entries displayed : 0",
      Net::Connector::Hillstone::Topology => "Total lldp neighbor number: 0.",
      Net::Connector::PaloAlto::Topology => "No LLDP neighbors"
    }
    samples.each do |strategy_class, output|
      strategy = strategy_class.new(nil)
      assert_equal 0, strategy.expected_neighbor_count(output, nil)
      assert strategy.empty_neighbor_output?(output)
      refute strategy.empty_neighbor_output?("unexpected output")
    end
  end

  def test_shared_interface_normalization_preserves_existing_spellings
    strategy = Topology::Strategy.new(nil)
    {
      "XGE1/0/1" => "Ten-GigabitEthernet1/0/1",
      "GE1/0/1" => "GigabitEthernet1/0/1",
      "Gi1/0/1" => "GigabitEthernet1/0/1",
      "Te1/0/1" => "TenGigabitEthernet1/0/1",
      "Fa1/0/1" => "FastEthernet1/0/1",
      "Eth1/1" => "Ethernet1/1",
      "Po1" => "port-channel1"
    }.each do |discovered, configured|
      assert_equal configured, strategy.configuration_interface(discovered)
      assert_equal strategy.interface_key(configured), strategy.interface_key(discovered)
    end
  end

  def test_only_panos_commit_gets_an_extended_timeout
    strategy = Net::Connector::PaloAlto::Topology.new(nil)
    assert_equal 300, strategy.script_command("commit").timeout
    assert_equal "exit", strategy.script_command("exit")
    assert_equal "commit", Net::Connector::CiscoIos::Topology.new(nil).script_command("commit")
  end

  def test_read_only_topology_rejects_change_planning_without_device_io
    read_only = Class.new(Net::Connector::CiscoIos::Topology) do
      def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)
    end
    connector = Class.new(Net::Connector.vendor_class(:cisco_ios)) do
      profile { topology_strategy read_only }
    end
    device = connector.new(host: "192.0.2.1", username: "admin", transport: ConnectorFake.new)
    refute device.supports?(:interface_description_changes)
    error = assert_raises(Net::Connector::UnsupportedOperation) { device.plan_interface_descriptions }
    assert_equal :description_unsupported, error.code
    assert_equal 0, device.instance_variable_get(:@session).transport.opens
  end
end
