# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class TftpSourceInterfaceTest < Minitest::Test
  def test_h3c_management_uses_device_address_without_global_configuration
    %i[h3c h3c_wireless].each do |vendor|
      transport = ConnectorFake.new("<edge>", "File upload successfully.\n<edge>")
      device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: transport)
      receipt = device.tftp_backup(host: "192.0.2.10", path: "saved.cfg", source_file: "flash:/startup.cfg", source_interface: "management")
      assert_equal "saved.cfg", receipt.path
      assert_equal ["tftp 192.0.2.10 put flash:/startup.cfg saved.cfg source ip 192.0.2.1\n"], transport.writes
    ensure
      device&.close
    end
  end

  def test_h3c_literal_interface_is_validated_and_normalized
    transport = ConnectorFake.new("<edge>", "File upload successfully.\n<edge>")
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "audit", transport: transport)
    device.tftp_backup(host: "192.0.2.10", path: "saved.cfg", source_file: "flash:/startup.cfg", source_interface: "Vlan-interface10")
    assert_equal ["tftp 192.0.2.10 put flash:/startup.cfg saved.cfg source interface Vlan-interface 10\n"], transport.writes
  ensure
    device&.close
  end

  def test_radware_management_and_data_are_per_transfer_switches
    { "management" => "mgmt", "data" => "data" }.each do |value, flag|
      transport = ConnectorFake.new(">> Main#", "Configuration uploaded successfully\n>> Main#")
      device = Net::Connector.build(:radware, host: "192.0.2.1", username: "audit", transport: transport)
      device.tftp_backup(host: "192.0.2.10", path: "saved.tgz", source_interface: value)
      assert_equal ["/cfg/ptcfg 192.0.2.10 -tftp -#{flag}\n"], transport.writes
    ensure
      device&.close
    end
  end

  def test_invalid_or_unsupported_source_selection_is_rejected_before_device_io
    [[:h3c, "management; quit"], [:h3c, "data"], [:h3c, "Vlan-interface 10\nquit"],
     [:radware, "Ethernet1"], [:cisco_ios, "management"], [:huawei, "management"]].each do |vendor, value|
      transport = ConnectorFake.new
      device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: transport)
      assert_raises(ArgumentError) do
        device.tftp_backup(host: "192.0.2.10", path: "saved.cfg", source_interface: value)
      end
      assert_empty transport.writes
      refute device.connected?
    ensure
      device&.close
    end
  end
end
