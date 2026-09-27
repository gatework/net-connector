# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class CapabilitiesTest < Minitest::Test
  def test_all_vendor_capabilities_are_available_without_io
    Net::Connector.vendors.each do |vendor|
      transport = ConnectorFake.new
      device = Net::Connector.build(vendor, host: "192.0.2.1", username: "admin", transport: transport)
      %i[running_config backup tftp_backup].each { |capability| assert device.supports?(capability), "#{vendor}: #{capability}" }
      assert_equal vendor != :palo_alto, device.supports?(:save_config), vendor.to_s
      assert_equal vendor != :huawei, device.supports?(:interface_descriptions), vendor.to_s
      assert_equal !%i[huawei radware].include?(vendor), device.supports?(:neighbors), vendor.to_s
      assert_equal !%i[huawei radware palo_alto].include?(vendor), device.supports?(:interface_description_changes), vendor.to_s
      refute device.supports?(:unknown)
      refute device.supports?(nil)
      assert device.supports?("running_config")
      assert_equal 0, transport.opens
      assert_empty transport.writes
    end
  end

  def test_strategy_bindings_inherit_override_and_can_be_disabled
    parent = Net::Connector.vendor_class(:cisco_ios)
    original = parent.profile
    child = Class.new(parent) do
      profile do
        tftp_strategy nil
        topology_strategy nil
      end
    end
    device = child.new(transport: ConnectorFake.new)
    refute device.supports?(:tftp_backup)
    refute device.supports?(:neighbors)
    refute device.supports?(:interface_descriptions)
    assert device.supports?(:running_config)
    assert_same original, parent.profile
    assert original.tftp_strategy
    assert original.topology_strategy
    assert_nil child.profile.tftp_strategy
    assert_nil child.profile.topology_strategy
    inherited = Class.new(parent)
    assert_same original, inherited.profile
    assert_same original.tftp_strategy, inherited.profile.tftp_strategy
    assert_raises(Net::Connector::UnsupportedOperation) { device.tftp_backup(host: "192.0.2.2") }
    error = assert_raises(Net::Connector::UnsupportedOperation) { device.neighbors }
    assert_equal :neighbor_discovery_unsupported, error.code
  end

  def test_invalid_strategy_bindings_are_rejected
    [:tftp_strategy, :topology_strategy, :running_config_strategy].each do |field|
      [Object, Object.new, "UnknownStrategy", false].each do |value|
        assert_raises(ArgumentError) { Net::Connector::Profile.new(**{ field => value }) }
      end
    end
  end

  def test_custom_strategy_binding_controls_execution_without_a_vendor_registry
    original = Net::Connector.vendor_class(:cisco_ios)
    custom_transfer = Class.new(original.profile.tftp_strategy) do
      def script(_target, **)
        Net::Connector::Script.new(["custom upload"])
      end

      def device_reported_complete?(result) = result.output.include?("custom upload complete")
    end
    custom_topology = Class.new(original.profile.topology_strategy) do
      def initialize(device)
        super
        raise "capability queries must not instantiate strategies"
      end
    end
    klass = Class.new(original)
    klass.profile do
      tftp_strategy custom_transfer
      topology_strategy custom_topology
    end
    transport = ConnectorFake.new("router#", "custom upload complete\nrouter#")
    device = klass.new(host: "192.0.2.1", username: "test", transport: transport)
    assert device.supports?(:neighbors)
    assert device.supports?(:tftp_backup)
    assert_equal 0, transport.opens
    assert_equal "custom.cfg", device.tftp_backup(host: "192.0.2.2", path: "custom.cfg").path
    assert_equal ["custom upload\n"], transport.writes
    assert_same custom_transfer, klass.profile.tftp_strategy
    refute_same custom_transfer, original.profile.tftp_strategy
  ensure
    device&.close
  end

  def test_method_based_custom_collection_remains_supported
    klass = Class.new(Net::Connector::Base) do
      profile { prompts { login(/device>/); command(/device>/) } }

      def config_commands = ["collect"]

      def save_commands = ["save"]
    end
    device = klass.new(transport: ConnectorFake.new)
    assert device.supports?(:running_config)
    assert device.supports?(:backup)
    assert device.supports?(:save_config)
    refute device.supports?(:tftp_backup)
    empty = Class.new(klass) do
      def config_commands = []

      def save_commands = []
    end.new(transport: ConnectorFake.new)
    refute empty.supports?(:running_config)
    refute empty.supports?(:save_config)
  end
end
