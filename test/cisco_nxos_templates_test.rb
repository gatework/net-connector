# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class CiscoNxosTemplatesTest < Minitest::Test
  def teardown = @device&.close

  def test_ip_interface_brief_keeps_vrf_and_all_three_states
    output = <<~OUTPUT
      IP Interface Status for VRF "default"(1)
      Interface            IP Address      Interface Status
      Vlan20               192.0.2.20      protocol-up/link-up/admin-up
      IP Interface Status for VRF "management"(2)
      Interface            IP Address      Interface Status
      mgmt0                192.0.2.21      protocol-down/link-down/admin-up
    OUTPUT
    build(output)
    assert_equal [
      { "VRF" => "default", "INTERFACE" => "Vlan20", "IP_ADDRESS" => "192.0.2.20",
        "PROTOCOL" => "up", "LINK_STATUS" => "up", "ADMIN_STATUS" => "up" },
      { "VRF" => "management", "INTERFACE" => "mgmt0", "IP_ADDRESS" => "192.0.2.21",
        "PROTOCOL" => "down", "LINK_STATUS" => "down", "ADMIN_STATUS" => "up" }
    ], @device.parse_command("show ip interface brief vrf all")
  end

  def test_cdp_details_keep_neighbor_block_boundaries
    build("Device ID:leaf-b(SERIAL01)\nSystem Name: leaf-b\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n" \
          "Device ID:core-c\nInterface: Ethernet1/3, Port ID (outgoing port): Ethernet2/1\n")
    neighbors = @device.neighbors
    assert_equal ["leaf-b(SERIAL01)", "core-c"], neighbors.map(&:neighbor_name)
    assert_equal %w[Ethernet1/1 Ethernet1/3], neighbors.map(&:local_interface)
    assert_equal %w[Ethernet1/2 Ethernet2/1], neighbors.map(&:neighbor_interface)
    assert(neighbors.all? { |neighbor| neighbor.protocol == :cdp })
  end

  def test_partial_cdp_block_cannot_borrow_fields_from_another_neighbor
    ["Device ID:incomplete\nDevice ID:complete\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n",
     "Device ID:complete\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\nDevice ID:\n"].each do |output|
      build(output)
      error = assert_raises(Net::Connector::ParsingError) { @device.neighbors }
      assert_equal :unrecognized_output, error.code
      @device.close
    end
  end

  def test_running_config_stops_each_interface_at_its_own_configuration_boundary
    config = <<~CONFIG
      interface Ethernet1/1
        description uplink
        no shutdown

      interface Ethernet1/2
        no shutdown
      route-map SITE permit 10
        description routing-policy
      interface port-channel10
        description aggregate
    CONFIG
    @device = Net::Connector.build(:cisco_nxos, host: "192.0.2.1", username: "audit",
                                    transport: ConnectorFake.new("switch#", "switch#", "#{config}switch#"))
    assert_equal({ "ethernet1/1" => "uplink", "ethernet1/2" => "", "port-channel10" => "aggregate" },
                 @device.interface_descriptions)
  end

  private

  def build(output)
    @device = Net::Connector.build(:cisco_nxos, host: "192.0.2.1", username: "audit",
                                    transport: ConnectorFake.new("switch#", "#{output}switch#"))
  end
end
