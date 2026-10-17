# frozen_string_literal: true

require "minitest/autorun"
require "logger"
require "stringio"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class RemoteBackupTest < Minitest::Test
  PROMPT = "audit@srx01> "

  def teardown = @device&.close

  def test_juniper_exports_committed_configuration_over_scp_and_ftp
    %i[scp ftp].each do |protocol|
      url = "#{protocol}://archive@192.0.2.10/site/srx.cfg"
      build("#{url} 100% of 1356 B\nWrote 59 lines of output to '#{url}'\n#{PROMPT}")
      receipt = @device.remote_backup(host: "192.0.2.10", path: "site/srx.cfg", username: "archive", protocol: protocol)
      assert_equal ["show configuration | save #{url}\n"], @transport.writes
      assert_equal ["192.0.2.10", "site/srx.cfg", protocol, "archive", :running, :device_reported],
                   receipt.to_h.values_at(:server, :path, :protocol, :username, :configuration_kind, :verification)
      assert receipt.frozen?
      assert receipt.path.frozen?
      assert receipt.completed_at.frozen?
      @device.close
    end
  end

  def test_remote_password_is_answered_once_and_never_logged_or_retained_in_receipt
    secret = "remote-fixture-passphrase"
    log = StringIO.new
    url = "ftp://archive@backup.example/srx.cfg"
    build("Password for archive@backup.example:", "Wrote 3 lines of output to '#{url}'\n#{PROMPT}",
          logger: Logger.new(log, level: Logger::DEBUG))
    receipt = @device.remote_backup(host: "backup.example", path: "srx.cfg", username: "archive", protocol: :ftp, password: secret)
    assert_equal "#{secret}\n", @transport.writes.last
    refute_includes receipt.inspect, secret
    @device.close
    refute_includes log.string, secret
  end

  def test_password_challenge_does_not_trust_scp_host_keys_implicitly
    build("The authenticity of host cannot be established.\nAre you sure you want to continue connecting (yes/no)?")
    assert_raises(Net::Connector::CommandTimeout) do
      @device.remote_backup(host: "192.0.2.10", path: "srx.cfg", username: "archive", password: "fixture")
    end
    assert_equal 1, @transport.writes.size
  end

  def test_missing_or_wrong_completion_evidence_never_returns_a_receipt
    ["", "100% of 1356 B\n", "Wrote 0 lines of output to 'scp://archive@192.0.2.10/srx.cfg'\n",
     "Wrote 3 lines of output to 'scp://archive@other.example/srx.cfg'\n"].each do |output|
      build("#{output}#{PROMPT}")
      error = assert_raises(Net::Connector::DeviceError) do
        @device.remote_backup(host: "192.0.2.10", path: "srx.cfg", username: "archive")
      end
      assert_equal :transfer_unconfirmed, error.code
      @device.close
    end
  end

  def test_error_after_progress_cannot_be_reported_as_a_successful_export
    build("100% of 1356 B\nerror: could not send local copy of file\n#{PROMPT}")
    assert_raises(Net::Connector::DeviceError) do
      @device.remote_backup(host: "192.0.2.10", path: "srx.cfg", username: "archive")
    end
  end

  def test_failure_words_in_destination_do_not_override_exact_completion
    url = "scp://archive@192.0.2.10/failed.cfg"
    build("Wrote 3 lines of output to '#{url}'\n#{PROMPT}")
    assert_equal "failed.cfg", @device.remote_backup(host: "192.0.2.10", path: "failed.cfg", username: "archive").path
  end

  def test_completed_upload_retains_receipt_when_session_finalization_fails
    url = "scp://archive@192.0.2.10/srx.cfg"
    build("Wrote 3 lines of output to '#{url}'\n#{PROMPT}")
    @device.define_singleton_method(:with_operation) do |*arguments, &block|
      super(*arguments, &block)
      raise IOError, "private-finalization-diagnostic"
    end
    error = assert_raises(Net::Connector::RemoteBackup::CompletionError) do
      @device.remote_backup(host: "192.0.2.10", path: "srx.cfg", username: "archive")
    end
    assert_equal "srx.cfg", error.receipt.path
    assert_equal :transfer_finalize_failed, error.code
    assert_equal "IOError", error.underlying_type
    assert_nil error.cause
    refute_includes error.full_message, "private-finalization-diagnostic"
    assert_equal 1, @transport.writes.size
  end

  def test_invalid_export_arguments_perform_no_device_io
    [{ protocol: :tftp }, { protocol: "scp" }, { username: "archive;quit" }, { username: "user:password" },
     { path: "../srx.cfg" }, { path: "x\ncommit" }, { host: "host;commit" }, { password: "x\ncommit" },
     { password: 123 }].each do |override|
      build
      options = { host: "192.0.2.10", path: "srx.cfg", username: "archive" }.merge(override)
      assert_raises(ArgumentError) { @device.remote_backup(**options) }
      assert_equal 0, @transport.opens
      @device.close
    end
  end

  def test_remote_export_strategy_can_be_disabled_in_a_subclass_without_changing_parent
    parent = Net::Connector.vendor_class(:juniper)
    child = Class.new(parent) { profile { remote_backup_strategy nil } }
    @transport = ConnectorFake.new
    @device = child.new(host: "192.0.2.1", username: "audit", transport: @transport)
    refute @device.supports?(:remote_backup)
    assert parent.profile.remote_backup_strategy
    assert_raises(Net::Connector::UnsupportedOperation) do
      @device.remote_backup(host: "192.0.2.10", path: "srx.cfg", username: "archive")
    end
    assert_equal 0, @transport.opens
  end

  private

  def build(*events, **options)
    @transport = ConnectorFake.new(PROMPT, *events)
    @device = Net::Connector.build(:juniper, host: "192.0.2.1", username: "audit", transport: @transport, **options)
  end
end
