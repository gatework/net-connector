# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/device/remote_backup/receipt"

class RemoteBackupReceiptTest < Minitest::Test
  def receipt
    Net::Connector::RemoteBackup::Receipt.new(server: "192.0.2.1", path: "switch.cfg", protocol: :scp,
                                               username: "archive", completed_at: Time.utc(2026, 1, 1))
  end

  def test_updates_validate_protocol_and_completion_evidence
    [{ protocol: :tftp }, { verification: :server_verified }, { completed_at: nil },
     { path: "../switch.cfg" }, { username: "user;quit" }, { configuration_kind: :candidate }].each do |attributes|
      assert_raises(ArgumentError) { receipt.with(**attributes) }
    end
  end

  def test_updates_own_mutable_strings_and_times
    path = +"next.cfg"
    time = Time.utc(2026, 2, 1)
    updated = receipt.with(path: path, completed_at: time)
    path.clear
    time.localtime("+08:00")
    assert_equal "next.cfg", updated.path
    assert updated.completed_at.utc?
    assert updated.path.frozen?
    assert updated.completed_at.frozen?
  end
end
