# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class VendorTransferContractTest < Minitest::Test
  def teardown = @device&.close

  def test_supported_user_view_finishes_read_only_commands_without_implicit_privilege_changes
    %i[centec cisco_ios cisco_nxos].each do |vendor|
      @device&.close
      transport = ConnectorFake.new("Switch>", "show version\nVersion 1.0\nSwitch>")
      @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "reader", transport: transport)
      result = @device.execute_command("show version")
      assert result.success?, "#{vendor}: #{result.error.inspect}"
      assert_includes result.output, "Version 1.0"
      assert_equal ["show version\n"], transport.writes
    end
  end

  def test_centec_completed_upload_in_user_view_is_not_lost_as_a_timeout
    transport = ConnectorFake.new("Switch>", "Sent 3664 bytes in 0.1 seconds\nSwitch>")
    @device = Net::Connector.build(:centec, host: "192.0.2.1", username: "reader", transport: transport)
    receipt = @device.tftp_backup(host: "192.0.2.10", path: "requested.cfg")
    assert_equal "requested.cfg", receipt.path
    assert_equal 1, transport.writes.size
  end

  def test_radware_preserves_the_actual_different_filename_in_a_completion_error
    radware("192.0.2.10:different.tgz")
    error = assert_raises(Net::Connector::TftpCompletionError) do
      @device.tftp_backup(host: "192.0.2.10", path: "requested.tgz")
    end
    assert_equal :transfer_path_mismatch, error.code
    assert_equal "different.tgz", error.receipt.path
    assert_equal "requested.tgz", error.receipt.requested_path
  end

  def test_radware_different_server_cannot_confirm_the_requested_target
    radware("192.0.2.99:requested.tgz")
    error = assert_raises(Net::Connector::TftpCompletionError) do
      @device.tftp_backup(host: "192.0.2.10", path: "requested.tgz")
    end
    assert_equal :transfer_path_unconfirmed, error.code
    assert_nil error.receipt.path
  end

  def test_radware_conflicting_completion_destinations_are_not_arbitrarily_selected
    radware("192.0.2.10:requested.tgz", "192.0.2.10:different.tgz")
    error = assert_raises(Net::Connector::TftpCompletionError) do
      @device.tftp_backup(host: "192.0.2.10", path: "requested.tgz")
    end
    assert_equal :transfer_path_unconfirmed, error.code
    assert_nil error.receipt.path
  end

  def test_radware_matching_dns_destination_is_case_insensitive
    radware("TFTP.EXAMPLE:requested.tgz")
    receipt = @device.tftp_backup(host: "tftp.example", path: "requested.tgz")
    assert_equal "tftp.example", receipt.server
    assert_equal "requested.tgz", receipt.path
  end

  private

  def radware(*destinations)
    completion = destinations.map { |destination| "Current config successfully transferred to #{destination}" }.join("\n")
    transport = ConnectorFake.new(">> Main#", "#{completion}\n>> Main#")
    @device = Net::Connector.build(:radware, host: "192.0.2.1", username: "reader", transport: transport)
  end
end
