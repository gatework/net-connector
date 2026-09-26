# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class TopologyTest < Minitest::Test
  class Device
    attr_reader :vendor, :host, :commands, :script
    attr_accessor :neighbor_output, :config_output, :on_execute

    def initialize(vendor:, neighbor_output:, config_output: "")
      @vendor = vendor
      @host = "192.0.2.10"
      @neighbor_output = neighbor_output
      @config_output = config_output
      @commands = []
    end

    def execute(command)
      @commands << command
      Net::Connector::Result.new(config: neighbor_output)
    end

    def running_config = Net::Connector::Result.new(config: config_output)

    def with_operation(_name) = yield

    def profile = Struct.new(:save_commands, :topology_strategy).new({ h3c: ["save force"], hillstone: ["save all"] }.fetch(vendor, []), Net::Connector.vendor_class(vendor).profile.topology_strategy)

    def execute_script(script)
      @script = script
      on_execute&.call(script)
      Net::Connector::Result.new
    end
  end

  def test_unsupported_vendor_rejects_nonempty_forged_plan_without_network_calls
    device = Device.new(vendor: :huawei, neighbor_output: "")
    topology = Net::Connector::Operations::Topology.new(device)
    plan = Net::Connector::Operations::Topology::Plan.new(
      host: device.host, vendor: device.vendor, evidence: {}, changes: [Object.new], commands: ["reload"]
    )

    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.apply(plan, confirmed: true) }
    assert_equal :neighbor_discovery_unsupported, error.code
    assert_empty device.commands
    assert_nil device.script
    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.descriptions }
    assert_equal :description_unsupported, error.code
  end

  def test_custom_read_only_strategy_allows_reads_and_rejects_planning_and_apply
    read_only = Class.new(Net::Connector::Operations::Topology::Cisco) do
      def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)
    end
    device = Device.new(vendor: :cisco_ios, neighbor_output: "Total cdp entries displayed : 0")
    profile = device.profile
    profile.topology_strategy = read_only
    device.define_singleton_method(:profile) { profile }
    topology = Net::Connector::Operations::Topology.new(device)
    assert_empty topology.neighbors
    assert_empty topology.descriptions
    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.plan_descriptions }
    assert_equal :description_unsupported, error.code
    assert_equal :plan, error.phase

    plan = Net::Connector::Operations::Topology::Plan.new(
      host: device.host, vendor: device.vendor, evidence: {}, changes: [Object.new], commands: ["reload"]
    )
    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.apply(plan, confirmed: true) }
    assert_equal :description_unsupported, error.code
    assert_equal :apply, error.phase
    assert_nil device.script

    disabled = Class.new(read_only) do
      def self.supports?(_capability) = false
    end
    profile.topology_strategy = disabled
    topology = Net::Connector::Operations::Topology.new(device)
    device.commands.clear
    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.neighbors }
    assert_equal :neighbor_discovery_unsupported, error.code
    assert_empty device.commands
    assert_raises(Net::Connector::UnsupportedOperation) { topology.descriptions }
  end

  def test_h3c_old_and_new_lldp_column_orders
    samples = [
      "System Name          Local Interface   Chassis ID         Port ID\n" \
      "switch-a             XGE1/0/1         000f-e25d-ee91     Ten-GigabitEthernet1/0/2\n",
      "Local Interface   Chassis ID       Port ID                   System Name\n" \
      "XGE1/0/1         000f-e25d-ee91   Ten-GigabitEthernet1/0/2 switch-a\n",
      "LocalIf   Nbr chassis ID  Nbr port ID                Nbr system name\n" \
      "XGE1/0/1 000f-e25d-ee91 Ten-GigabitEthernet1/0/2 switch-a\n"
    ]
    samples.each do |output|
      device = Device.new(vendor: :h3c, neighbor_output: output)
      neighbor = Net::Connector::Operations::Topology.new(device).neighbors.fetch(0)
      assert_equal "XGE1/0/1", neighbor.local_interface
      assert_equal "switch-a", neighbor.neighbor_name
      assert_equal "Ten-GigabitEthernet1/0/2", neighbor.neighbor_interface
      assert_equal :lldp, neighbor.protocol
    end

    device = Device.new(vendor: :h3c, neighbor_output: "Local Interface Chassis ID Port ID System Name\n" \
                         "GE1/0/1 000f-e25d-ee91 Port 12 switch-b\n")
    assert_equal "Port 12", Net::Connector::Operations::Topology.new(device).neighbors.fetch(0).neighbor_interface
  end

  def test_hillstone_and_palo_alto_lldp
    hillstone = Device.new(vendor: :hillstone, neighbor_output: <<~OUTPUT)
      Total lldp neighbor number: 1.
      System Name      Local Interface  Chassis ID       Port ID
      switch-b         ethernet0/1      7425.8ae4.4f4c   GigabitEthernet2/0
    OUTPUT
    panos = Device.new(vendor: :palo_alto, neighbor_output: <<~OUTPUT)
      Index 1
      Local interface: ethernet1/1
      Neighbor information:
      Chassis ID: 7425.8ae4.4f4c
      Port ID: Ethernet1/2
      System name: switch-b
      Local information:
    OUTPUT
    [hillstone, panos].each do |device|
      neighbor = Net::Connector::Operations::Topology.new(device).neighbors.fetch(0)
      assert_equal "switch-b", neighbor.neighbor_name
      assert_equal :lldp, neighbor.protocol
    end
  end

  def test_palo_alto_ignores_explicitly_empty_local_lldp_blocks
    empty = <<~OUTPUT
      Local information:
      Index 76
      Local interface: ethernet1/13
      Local Port ID: 61
      Neighbor information:
    OUTPUT
    full = <<~OUTPUT
      Local information:
      Index 77
      Local interface: ethernet1/14
      Local Port ID: 62
      Neighbor information:
      Chassis ID: 7425.8ae4.4f4c
      Port ID: Ethernet1/2
      System name: switch-b
    OUTPUT
    device = Device.new(vendor: :palo_alto, neighbor_output: empty)
    assert_empty Net::Connector::Operations::Topology.new(device).neighbors
    device.neighbor_output = full + empty
    neighbors = Net::Connector::Operations::Topology.new(device).neighbors
    assert_equal ["ethernet1/14"], neighbors.map(&:local_interface)
    device.neighbor_output = full.sub("Port ID: Ethernet1/2\n", "") + empty
    error = assert_raises(Net::Connector::ParsingError) { Net::Connector::Operations::Topology.new(device).neighbors }
    assert_equal :unrecognized_output, error.code
  end

  def test_cisco_uses_cdp_and_radware_reports_unsupported
    device = Device.new(vendor: :cisco_nxos, neighbor_output: <<~OUTPUT)
      Device ID: leaf-b
      Platform: N9K-C93180, Capabilities: Router Switch
      Interface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2
    OUTPUT
    neighbor = Net::Connector::Operations::Topology.new(device).neighbors.fetch(0)
    assert_equal :cdp, neighbor.protocol
    assert_equal "leaf-b", neighbor.neighbor_name
    assert_equal ["show cdp neighbors detail"], device.commands

    radware = Device.new(vendor: :radware, neighbor_output: "")
    error = assert_raises(Net::Connector::UnsupportedOperation) do
      Net::Connector::Operations::Topology.new(radware).neighbors
    end
    assert_equal :neighbor_discovery_unsupported, error.code
    assert_empty radware.commands
  end

  def test_palo_alto_plan_contains_commit_and_uses_existing_comment
    device = Device.new(vendor: :palo_alto, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Local interface: ethernet1/1
      Port ID: Ethernet1/2
      System name: switch-b
    OUTPUT
      set network interface ethernet ethernet1/1 comment "old uplink"
    CONFIG
    topology = Net::Connector::Operations::Topology.new(device)
    plan = topology.plan_descriptions
    assert_equal "old uplink", plan.changes.fetch(0).old_description
    assert_equal ["configure", 'set network interface ethernet ethernet1/1 comment "To switch-b Eth1/2"',
                  "commit", "exit"], plan.commands
    device.on_execute = ->(_) { device.config_output = device.config_output.sub("old uplink", "To switch-b Eth1/2") }
    assert topology.apply(plan, confirmed: true).success?
    assert_equal 300, device.script.find { |command| command.text == "commit" }.timeout
  end

  def test_hillstone_plan_and_cisco_description_parsing
    hillstone = Device.new(vendor: :hillstone, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Total lldp neighbor number: 1.
      System Name Local Interface Chassis ID Port ID
      switch-b ethernet0/1 7425.8ae4.4f4c GigabitEthernet2/0
    OUTPUT
      interface ethernet0/1
       description existing
      exit
    CONFIG
    plan = Net::Connector::Operations::Topology.new(hillstone).plan_descriptions
    assert_equal ["configure", "interface ethernet0/1", "description To switch-b Gi2/0",
                  "exit", "exit", "save all"], plan.commands

    cisco = Device.new(vendor: :cisco_ios, neighbor_output: "", config_output: <<~CONFIG)
      interface GigabitEthernet1/0/1
       description uplink
      !
    CONFIG
    assert_equal({ "gigabitethernet1/0/1" => "uplink" }, Net::Connector::Operations::Topology.new(cisco).descriptions)

    cisco.neighbor_output = <<~OUTPUT
      Device ID: switch-c
      Interface: Gi1/0/1, Port ID (outgoing port): Gi1/0/2
    OUTPUT
    assert_equal "uplink", Net::Connector::Operations::Topology.new(cisco).plan_descriptions.changes.fetch(0).old_description
  end

  def test_radware_port_names_are_read_from_configuration_dump
    device = Device.new(vendor: :radware, neighbor_output: "", config_output: <<~CONFIG)
      script start "Alteon" 4
      /c/port 1
        name "uplink to core"
      /c/port 2
        pvid 10
      /c/l2/vlan 10
      /cfg/port 3/name "backup link"
    CONFIG
    assert_equal({ "1" => "uplink to core", "2" => "", "3" => "backup link" },
                 Net::Connector::Operations::Topology.new(device).descriptions)
  end

  def test_description_formatting_keeps_original_evidence_and_custom_formatter_input
    device = Device.new(vendor: :cisco_ios, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Device ID: Core-SW
      Interface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2
    OUTPUT
      interface Ethernet1/1
       description old uplink
      !
    CONFIG
    topology = Net::Connector::Operations::Topology.new(device)
    plan = topology.plan_descriptions
    assert_equal "To Core-SW Eth1/2", plan.changes.first.new_description
    assert_equal "Ethernet1/1", plan.changes.first.interface
    assert_equal "Ethernet1/2", plan.changes.first.neighbor.neighbor_interface
    assert_equal ["Core-SW", "Ethernet1/2", "old uplink"], plan.evidence.fetch("ethernet1/1")
    assert_equal "To Core-SW eth1/2", topology.plan_descriptions(lowercase: true).changes.first.new_description
    assert_equal "To Core-SW Ethernet1/2", topology.plan_descriptions(abbreviate: false).changes.first.new_description
    assert_equal "Ethernet1/2", topology.plan_descriptions { |neighbor| neighbor.neighbor_interface }.changes.first.new_description

    device.on_execute = ->(_) { device.config_output = device.config_output.sub("old uplink", "To Core-SW Eth1/2") }
    assert topology.apply(plan, confirmed: true).success?
    assert_empty topology.plan_descriptions.changes
    assert_empty topology.plan_descriptions.commands
  end

  def test_plan_requires_confirmation_and_rechecks_evidence
    device = Device.new(vendor: :h3c, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Local Interface   Chassis ID       Port ID                   System Name
      XGE1/0/1         000f-e25d-ee91   Ten-GigabitEthernet1/0/2 switch-a
    OUTPUT
      interface Ten-GigabitEthernet1/0/1
       description old uplink
      #
    CONFIG
    topology = Net::Connector::Operations::Topology.new(device)
    plan = topology.plan_descriptions
    assert_equal "old uplink", plan.changes.fetch(0).old_description
    assert_equal "To switch-a Te1/0/2", plan.changes.fetch(0).new_description
    assert_equal ["system-view", "interface Ten-GigabitEthernet1/0/1", "description To switch-a Te1/0/2",
                  "quit", "return", "save force"], plan.commands

    error = assert_raises(Net::Connector::UnsupportedOperation) { topology.apply(plan) }
    assert_equal :confirmation_required, error.code
    assert_nil device.script

    device.config_output = device.config_output.sub("old uplink", "changed by another admin")
    error = assert_raises(Net::Connector::DeviceError) { topology.apply(plan, confirmed: true) }
    assert_equal :stale_plan, error.code
    assert_nil device.script

    device.config_output = device.config_output.sub("changed by another admin", "old uplink")
    device.on_execute = ->(_) { device.config_output = device.config_output.sub("old uplink", "To switch-a Te1/0/2") }
    assert topology.apply(plan, confirmed: true).success?
    assert_equal plan.commands, (device.script.map { |command| command.text })
  end

  def test_successful_script_without_matching_readback_is_unconfirmed
    device = Device.new(vendor: :cisco_ios, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Device ID: switch-c
      Interface: GigabitEthernet1/0/1, Port ID (outgoing port): GigabitEthernet1/0/2
    OUTPUT
      interface GigabitEthernet1/0/1
       description old uplink
      !
    CONFIG
    topology = Net::Connector::Operations::Topology.new(device)
    result = topology.apply(topology.plan_descriptions, confirmed: true)
    assert result.failure?
    assert_equal :description_unconfirmed, result.error.code
  end

  def test_invalid_and_ambiguous_neighbor_output_does_not_produce_a_plan
    device = Device.new(vendor: :h3c, neighbor_output: "unexpected output\n")
    error = assert_raises(Net::Connector::ParsingError) do
      Net::Connector::Operations::Topology.new(device).neighbors
    end
    assert_equal :unrecognized_output, error.code

    device.neighbor_output = "Local Interface Chassis ID Port ID System Name\n" \
                             "GE1/0/1 000f-e25d-ee91 GE1/0/2 switch-a\n" \
                             "GE1/0/1 000f-e25d-ee92 GE1/0/3 switch-b\n"
    error = assert_raises(Net::Connector::ParsingError) do
      Net::Connector::Operations::Topology.new(device).plan_descriptions
    end
    assert_equal :ambiguous_neighbor, error.code
  end

  def test_partial_neighbor_parse_is_rejected
    device = Device.new(vendor: :h3c, neighbor_output: <<~OUTPUT)
      Local Interface Chassis ID Port ID System Name
      GE1/0/1 000f-e25d-ee91 GE1/0/2 switch-a
      GE1/0/3 000f-e25d-ee92 unexpected port format switch-b
    OUTPUT
    error = assert_raises(Net::Connector::ParsingError) do
      Net::Connector::Operations::Topology.new(device).neighbors
    end
    assert_equal :unrecognized_output, error.code

    device = Device.new(vendor: :hillstone, neighbor_output: <<~OUTPUT)
      Total lldp neighbor number: 2.
      System Name Local Interface Chassis ID Port ID
      switch-a ethernet0/1 7425.8ae4.4f4c ethernet0/2
    OUTPUT
    error = assert_raises(Net::Connector::ParsingError) do
      Net::Connector::Operations::Topology.new(device).neighbors
    end
    assert_equal :unrecognized_output, error.code
  end

  def test_unknown_rows_are_not_empty_or_complete_neighbor_tables
    %i[h3c hillstone].each do |vendor|
      known = vendor == :h3c ? "peer GE1/0/1 000f-e25d-ee91 GE1/0/2" :
                              "peer ethernet0/1 7425.8ae4.4f4c ethernet0/2"
      ["", "#{known}\n"].each do |prefix|
        output = "System Name Local Interface Chassis ID Port ID\n#{prefix}unrecognized neighbor format with extra columns\n"
        device = Device.new(vendor: vendor, neighbor_output: output)
        error = assert_raises(Net::Connector::ParsingError) do
          Net::Connector::Operations::Topology.new(device).neighbors
        end
        assert_equal :unrecognized_output, error.code
      end
    end
  end

  def test_changed_neighbor_chassis_invalidates_description_plan
    device = Device.new(vendor: :h3c, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Local Interface Chassis ID Port ID System Name
      GE1/0/1 000f-e25d-ee91 GE1/0/2 switch-a
    OUTPUT
      interface GigabitEthernet1/0/1
       description old uplink
      #
    CONFIG
    topology = Net::Connector::Operations::Topology.new(device)
    plan = topology.plan_descriptions
    device.neighbor_output = device.neighbor_output.sub("000f-e25d-ee91", "000f-e25d-ee92")

    error = assert_raises(Net::Connector::DeviceError) { topology.apply(plan, confirmed: true) }

    assert_equal :stale_plan, error.code
    assert_nil device.script
  end

  def test_panos_multiline_comment_does_not_become_a_truncated_description
    device = Device.new(vendor: :palo_alto, neighbor_output: "", config_output: <<~CONFIG)
      set network interface ethernet ethernet1/1 comment "first line
      second line"
    CONFIG
    error = assert_raises(Net::Connector::ParsingError) do
      Net::Connector::Operations::Topology.new(device).descriptions
    end
    assert_equal :unrecognized_output, error.code
  end

  def test_empty_neighbor_tables_allow_headers_separators_and_cli_echo
    { h3c: "<device>", hillstone: "device#" }.each do |vendor, prompt|
      strategy = Net::Connector.vendor_class(vendor).profile.topology_strategy.new(nil)
      output = "#{strategy.neighbor_command}\nSystem Name Local Interface Chassis ID Port ID\n----------------\n#{prompt}"
      device = Device.new(vendor: vendor, neighbor_output: output)
      assert_empty Net::Connector::Operations::Topology.new(device).neighbors
    end
  end

  def test_missing_interface_and_conflicting_descriptions_block_planning
    device = Device.new(vendor: :h3c, neighbor_output: <<~OUTPUT, config_output: "hostname edge\n")
      Local Interface Chassis ID Port ID System Name
      GE1/0/1 000f-e25d-ee91 GE1/0/2 switch-a
    OUTPUT
    topology = Net::Connector::Operations::Topology.new(device)
    error = assert_raises(Net::Connector::ParsingError) { topology.plan_descriptions }
    assert_equal :interface_missing, error.code

    device.config_output = "interface GigabitEthernet1/0/1\n description first\n#\n" \
                           "interface GigabitEthernet1/0/1\n description second\n#\n"
    error = assert_raises(Net::Connector::ParsingError) { topology.descriptions }
    assert_equal :ambiguous_description, error.code
  end

  def test_palo_alto_interface_without_comment_is_known_and_later_lines_do_not_erase_comment
    device = Device.new(vendor: :palo_alto, neighbor_output: <<~OUTPUT, config_output: <<~CONFIG)
      Local interface: ethernet1/1
      Port ID: Ethernet1/2
      System name: switch-b
    OUTPUT
      set network interface ethernet ethernet1/1 link-state auto
      set network interface ethernet ethernet1/2 comment "existing uplink"
      set network interface ethernet ethernet1/2 layer3 mtu 1500
    CONFIG
    topology = Net::Connector::Operations::Topology.new(device)
    assert_equal({ "ethernet1/1" => "", "ethernet1/2" => "existing uplink" }, topology.descriptions)
    assert_equal "", topology.plan_descriptions.changes.fetch(0).old_description
  end
end
