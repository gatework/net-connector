# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class CentecTest < Minitest::Test
  def test_running_configuration_removes_only_boundary_echoes
    body = "hostname Switch\nbanner motd ^\nSwitch#\nshow running-config\n^\n"
    with_device("terminal length 0\nSwitch#", "show running-config\n#{body}Switch# ") do |device, transport|
      assert_equal body, device.running_config.value!
      assert_equal ["terminal length 0\n", "show running-config\n"], transport.writes
    end
  end

  def test_management_and_data_exports_preserve_receipt_metadata
    { nil => "", "data" => "", "management" => " mgmt-if" }.each do |source, suffix|
      with_device("Sent 3664 bytes in 0.1 seconds\r\nSwitch#") do |device, transport|
        receipt = device.tftp_backup(host: "192.0.2.10", path: "backup.cfg", source_interface: source)
        assert_equal ["copy running-config#{suffix} tftp://192.0.2.10/backup.cfg\n"], transport.writes
        assert_equal "backup.cfg", receipt.path
        assert_equal :running, receipt.configuration_kind
        assert_equal :cfg, receipt.format
      end
    end
  end

  def test_echo_zero_bytes_and_future_messages_do_not_confirm_upload
    ["copy running-config tftp://192.0.2.10/backup.cfg", "Sent 0 bytes in 0.1 seconds",
     "Will send 3664 bytes", "Sent 3664 bytes in 0.1 seconds\nTransfer failed."].each do |message|
      with_device("#{message}\nSwitch#") do |device, _|
        error = assert_raises(Net::Connector::DeviceError) { device.tftp_backup(host: "192.0.2.10", path: "backup.cfg") }
        assert_equal(message.include?("failed") ? :transfer_failed : :transfer_unconfirmed, error.code)
      end
    end
  end

  def test_invalid_options_fail_before_connecting
    [{ source_file: "startup.cfg" }, { vrf: "management" }, { source_interface: "mgmt-if; save" }].each do |options|
      with_device do |device, transport|
        assert_raises(ArgumentError) { device.tftp_backup(host: "192.0.2.10", **options) }
        assert_equal 0, transport.opens
        assert_empty transport.writes
      end
    end
  end

  def test_inventory_mapping_and_per_host_transfer_policy
    rules = Net::Connector::Netdisco::Rules.new
    assert_equal :centec, rules.resolve("vendor" => "Centec Networks Inc.")
    assert_nil rules.resolve("vendor" => "NotCentec")
    policy = Net::Connector::Netdisco::Tftp::Policy.new(source_interfaces: {
      centec: { "default" => "management", "hosts" => { "192.0.2.2" => "data" } }
    })
    assert_equal "management", policy.for(host: "192.0.2.1", vendor: :centec).source_interface
    assert_equal "data", policy.for(host: "192.0.2.2", vendor: :centec).source_interface
  end

  private

  def with_device(*events)
    transport = ConnectorFake.new("Switch#", *events)
    device = Net::Connector.build(:centec, host: "192.0.2.1", username: "reader", transport: transport)
    yield device, transport
  ensure
    device&.close
  end
end
