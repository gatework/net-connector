# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "timeout"
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
      outcome = original.outcomes.first
      check = ->(&block) { checker.upload_and_verify(outcome.device, path: "backup.cfg", &block) }
      refute original.with(outcomes: [check.call { outcome }]).policy_success?
      path = File.join(directory, "backup.cfg")
      empty = check.call { File.write(path, ""); outcome }
      assert_equal :device_reported, empty.backup.verification
      File.write(path, "old")
      File.utime(Time.now - 60, Time.now - 60, path)
      assert_equal :device_reported, check.call { outcome }.backup.verification
      result = check.call { File.write(path, "configuration"); outcome }
      verified = original.with(outcomes: [result])
      assert verified.policy_success?
      assert_equal :device_reported, original.outcomes.first.backup.verification
      assert_equal Digest::SHA256.hexdigest("configuration"), verified.outcomes.first.backup.server_sha256
      assert_equal({ verified: 1, unverified: 0 }, verified.summary[:verification])
      File.unlink(path)
      File.symlink(File.join(directory, "missing"), path)
      assert_raises(ArgumentError) { check.call { flunk "unsafe target must reject before upload" } }
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
    outcome = original.outcomes.first
    assert_same outcome, N::TftpVerification.new.upload_and_verify(outcome.device) { outcome }
    assert original.policy_success?
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "backup.cfg"), "configuration")
        File.symlink(outside, File.join(root, "escape"))
        checker = N::TftpVerification.new(root: root)
        assert_raises(ArgumentError) do
          checker.upload_and_verify(outcome.device, path: "escape/backup.cfg") { flunk "must stay inside root" }
        end
      end
    end
  end

  def test_unchanged_future_timestamp_is_not_upload_evidence
    Dir.mktmpdir do |directory|
      checker = N::TftpVerification.new(root: directory)
      path = File.join(directory, "backup.cfg")
      File.write(path, "old configuration")
      future = Time.now + 3600
      File.utime(future, future, path)
      outcome = report(policy: :verified).outcomes.first
      result = checker.upload_and_verify(outcome.device, path: "backup.cfg") { outcome }
      assert_same outcome, result
      assert_equal :device_reported, result.backup.verification
      assert_nil result.backup.server_sha256
      refute checker.respond_to?(:call), "post-hoc checks must not manufacture an upload baseline"
    end
  end

  def test_same_contents_reuploaded_are_verified_against_the_captured_file_state
    Dir.mktmpdir do |directory|
      checker = N::TftpVerification.new(root: directory)
      path = File.join(directory, "backup.cfg")
      File.write(path, "configuration")
      File.utime(Time.now - 60, Time.now - 60, path)
      outcome = report.outcomes.first
      result = checker.upload_and_verify(outcome.device, path: "backup.cfg") do
        File.write(path, "configuration")
        outcome
      end
      assert_equal :server_verified, result.backup.verification
      assert_equal Digest::SHA256.hexdigest("configuration"), result.backup.server_sha256
    end
  end

  def test_receipt_cannot_verify_a_file_outside_the_locked_requested_target
    Dir.mktmpdir do |directory|
      checker = N::TftpVerification.new(root: directory)
      outcome = report(path: "another.cfg").outcomes.first
      result = checker.upload_and_verify(outcome.device, path: "backup.cfg") do
        File.write(File.join(directory, "another.cfg"), "configuration")
        outcome
      end
      assert_same outcome, result
      assert_equal :device_reported, result.backup.verification
    end
  end

  def test_postupload_lock_cleanup_failure_keeps_the_verified_receipt
    Dir.mktmpdir do |directory|
      checker = N::TftpVerification.new(root: directory)
      outcome = report.outcomes.first
      lock = Net::Connector::Storage::BackupLock
      synchronize = lock.method(:synchronize)
      cleanup_failure = lambda do |path, **options, &block|
        synchronize.call(path, **options, &block)
        raise IOError, "lock cleanup failed"
      end
      result = lock.stub(:synchronize, cleanup_failure) do
        checker.upload_and_verify(outcome.device, path: "backup.cfg") do
          File.write(File.join(directory, "backup.cfg"), "configuration")
          outcome
        end
      end
      assert_equal :reported_with_error, result.status
      assert_equal :server_verified, result.backup.verification
      assert_equal Digest::SHA256.hexdigest("configuration"), result.backup.server_sha256
      assert_equal "IOError", result.diagnostic.error_type
    end
  end

  # 覆盖 Fleet 编排与回调时点：上传前已存在的未来文件不能满足 verified 策略。
  def test_fleet_verifies_before_callbacks_and_rejects_unchanged_future_files
    [false, true].each do |write_upload|
      Dir.mktmpdir do |directory|
        row = { "ip" => "192.0.2.1", "vendor" => "H3C" }
        device = N::Device.from_row(row, rules: N::Rules.new)
        destination = File.join(directory, device.tftp_filename)
        File.write(destination, "old configuration")
        future = Time.now + 3600
        File.utime(future, future, destination)
        received = []
        observed = []
        closes = []
        factory = lambda do |item, _settings|
          connector = Object.new
          connector.define_singleton_method(:tftp_backup) do |host:, path:, **_options|
            received << path
            File.write(File.join(directory, path), "configuration") if write_upload
            Net::Connector::TftpReceipt.new(server: host, path: path, completed_at: Time.now.utc)
          end
          connector.define_singleton_method(:close) { closes << item.host }
          connector
        end
        fleet = N::Fleet.new(client: Struct.new(:devices).new([row]), settings: N::Settings.new(env: {}),
                             credentials: ->(*) { { username: "reader" } }, connector_factory: factory, result_store: nil)
        result = fleet.tftp_backup_all(server: "192.0.2.10", preserve_history: false, success_policy: :verified,
                                      verification_root: directory, on_result: ->(outcome) { observed << outcome })
        assert_equal write_upload, result.policy_success?
        assert_equal [device.tftp_filename], received
        assert_equal [device.host], closes
        assert_equal 1, observed.size
        assert_same observed.first, result.outcomes.first
        expected = write_upload ? :server_verified : :device_reported
        assert_equal expected, observed.first.backup.verification
        assert_equal expected, result.outcomes.first.backup.verification
      end
    end
  end

  # 等待者必须取得锁后才采集基线，不能把前一上传者的新文件冒充自己的结果。
  def test_same_target_serializes_the_upload_and_captures_each_baseline_after_waiting
    Dir.mktmpdir do |directory|
      checker = N::TftpVerification.new(root: directory)
      outcome = report.outcomes.first
      path = File.join(directory, "backup.cfg")
      first_started = Queue.new
      release = Queue.new
      second_started = Queue.new
      threads = []
      threads << Thread.new do
        checker.upload_and_verify(outcome.device, path: "backup.cfg") do
          first_started << true
          release.pop
          File.write(path, "configuration")
          outcome
        end
      end
      Timeout.timeout(2) { first_started.pop }
      threads << Thread.new do
        second_started << true
        checker.upload_and_verify(outcome.device, path: "backup.cfg") { outcome }
      end
      Timeout.timeout(2) do
        second_started.pop
        Thread.pass until threads.last.status == "sleep"
      end
      release << true
      first, second = Timeout.timeout(3) { threads.map(&:value) }
      assert_equal :server_verified, first.backup.verification
      assert_equal :device_reported, second.backup.verification
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      threads&.each(&:join)
    end
  end
end
