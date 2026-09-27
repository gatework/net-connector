# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/topology_fixture"

class OperationsReliabilityTest < Minitest::Test
  class Device
    attr_reader :vendor, :host, :script
    attr_accessor :description

    def initialize(vendor)
      @vendor = vendor
      @host = "192.0.2.10"
      @description = "existing uplink"
    end

    def execute(_command)
      output = if vendor == :palo_alto
                 "Local interface: ethernet1/1\nPort ID: Ethernet1/2\nSystem name: peer\n"
               else
                 "Device ID: peer\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n"
               end
      Net::Connector::Result.new(config: output)
    end

    def running_config
      config = if vendor == :palo_alto
                 "set network interface ethernet ethernet1/1 comment \"#{description}\"\n"
               else
                 "interface Ethernet1/1\n  description #{description}\n  switchport\n"
               end
      steps = config_commands.map { |text| completed(Net::Connector::Command.new(text, output_sensitive: true), config) }
      Net::Connector::Result.new(config: config, steps: steps)
    end

    def with_operation(_name) = yield

    def profile = Net::Connector.vendor_class(vendor).profile
    def config_commands = profile.config_commands

    def execute_script(script)
      @script = script
      steps = script.map do |command|
        self.description = command.text.delete_prefix("description ") if command.text.start_with?("description ")
        output = profile.save_commands.include?(command.text) ? TopologyFixture::SAMPLES.fetch(vendor).fetch(:saved) : ""
        completed(command, output)
      end
      Net::Connector::Result.new(steps: steps)
    end

    def completed(command, output)
      Net::Connector::CommandResult.new(command: command, output: output, prompt: "switch#", duration: 0)
    end
  end

  def test_nxos_indentation_preserves_old_description_and_confirms_readback
    device = Device.new(:cisco_nxos)
    topology = Net::Connector::Operations::Topology.new(device)
    plan = topology.plan_descriptions

    assert_equal "existing uplink", plan.changes.fetch(0).old_description
    assert topology.apply(plan, confirmed: true).success?
    assert_equal "To peer Eth1/2", device.description
  end

  def test_panos_requires_verified_candidate_ownership_instead_of_unconditionally_committing
    device = Device.new(:palo_alto)
    topology = Net::Connector::Operations::Topology.new(device)
    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.plan_descriptions }
    assert_equal :candidate_isolation_unavailable, error.code
    assert_equal "existing uplink", device.description
    assert_nil device.script
  end

  def test_tftp_failure_words_in_filenames_are_not_transfer_failures
    %w[failed.cfg error-backup.cfg timeout.cfg].each do |filename|
      device = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin",
                                    transport: ConnectorFake.new("fw#", "Export ok,target file name #{filename}\r\nfw#"))
      assert_equal filename, device.tftp_backup(host: "192.0.2.10", path: filename).path
    ensure
      device&.close
    end
  end

  def test_tftp_real_failure_after_success_is_preserved_with_sentence_punctuation
    device = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin",
                                  transport: ConnectorFake.new("fw#", "Export ok,target file name failed.cfg\nTransfer failed.\nfw#"))
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "failed.cfg")
    end
    assert_equal :transfer_failed, error.code
  ensure
    device&.close
  end

  def test_topology_plan_freezes_reviewed_values
    plan = Net::Connector::Operations::Topology.new(Device.new(:cisco_nxos)).plan_descriptions

    assert_raises(FrozenError) { plan.commands.first.replace("reload") }
    assert_raises(FrozenError) { plan.changes.first.new_description.replace("changed") }
    assert_raises(FrozenError) { plan.evidence.values.first.last.replace("changed") }
    assert_raises(FrozenError) { plan.changes.first.neighbor.neighbor_name.replace("changed") }
  end

  def test_tftp_failure_evidence_survives_color_and_carriage_return
    ["Transfer \e[31mfailed\e[0m.\n", "Transfer failed.\rTransfer complete.\n"].each do |output|
      transport = ConnectorFake.new("<H3C>", "Transfer complete.\n#{output}<H3C>")
      device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
      error = assert_raises(Net::Connector::DeviceError) do
        device.tftp_backup(host: "192.0.2.10", path: "backup.cfg", source_file: "startup.cfg")
      end
      assert_equal :transfer_failed, error.code
    ensure
      device&.close
    end
  end

  def test_default_tftp_filenames_accept_scoped_ipv6_addresses
    { cisco_ios: ["router#", "[OK]\nrouter#", "cfg"],
      radware: [">> device", "Configuration uploaded successfully\n>> device", "tgz"] }.each do |vendor, (prompt, output, extension)|
      device = Net::Connector.build(vendor, host: "fe80::1%en0", username: "admin",
                                    transport: ConnectorFake.new(prompt, output))
      result = device.tftp_backup(host: "192.0.2.10")
      assert_equal "fe80__1_en0.#{extension}", result.path
    ensure
      device&.close
    end
  end

  def test_topology_apply_rebuilds_commands_before_execution
    device = Device.new(:cisco_nxos)
    topology = Net::Connector::Operations::Topology.new(device)
    tampered = topology.plan_descriptions.with(commands: ["reload"])

    assert_raises(ArgumentError) { topology.apply(tampered, confirmed: true) }
    assert_nil device.script
  end
end
