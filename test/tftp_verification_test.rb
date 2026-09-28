# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class TftpVerificationTest < Minitest::Test
  N = Net::Connector::Netdisco

  def report(policy: :selected, path: "backup.cfg")
    now = Time.now.utc
    device = N::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "H3C" }, rules: N::Rules.new)
    receipt = Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: path, completed_at: now)
    item = N::Outcome.new(device: device, status: :reported_uploaded, backup: receipt,
                           error_code: nil, error_type: nil, started_at: now - 5, finished_at: now)
    N::Batch.new(mode: :tftp, outcomes: [item].freeze, started_at: now - 5, finished_at: now,
                 callback_errors: [], report_location: nil, report_error: nil).build_report(policy: policy)
  end

  def test_verified_policy_requires_current_nonempty_regular_server_file
    Dir.mktmpdir do |directory|
      checker = N::TftpVerification.new(root: directory)
      original = report(policy: :verified)
      refute checker.call(original).policy_success?
      path = File.join(directory, "backup.cfg")
      File.write(path, "")
      refute checker.call(original).policy_success?
      File.write(path, "old")
      File.utime(Time.now - 60, Time.now - 60, path)
      refute checker.call(original).policy_success?
      File.write(path, "configuration")
      verified = checker.call(original)
      assert verified.policy_success?
      assert_equal :device_reported, original.outcomes.first.backup.verification
      assert_equal Digest::SHA256.hexdigest("configuration"), verified.outcomes.first.backup.server_sha256
      assert_equal({ verified: 1, unverified: 0 }, verified.summary[:verification])
      File.unlink(path)
      File.symlink(File.join(directory, "missing"), path)
      refute checker.call(original).policy_success?
    end
  end

  def test_verified_policy_fails_before_inventory_when_used_without_verification_capability
    client = Object.new
    def client.devices = raise("inventory must not be read")
    fleet = N::Fleet.new(client: client, settings: N::Settings.new(env: {}))
    assert_raises(ArgumentError) { fleet.backup_all(success_policy: :verified) }
    assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.10", success_policy: :verified) }
  end

  def test_no_root_keeps_upload_evidence_and_symlinked_parent_cannot_escape_root
    original = report
    assert_same original, N::TftpVerification.new.call(original)
    assert original.policy_success?
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "backup.cfg"), "configuration")
        File.symlink(outside, File.join(root, "escape"))
        result = N::TftpVerification.new(root: root).call(report(policy: :verified, path: "escape/backup.cfg"))
        refute result.policy_success?
      end
    end
  end
end
