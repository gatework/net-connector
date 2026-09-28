# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require "tmpdir"
require "securerandom"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"
require_relative "support/tftp_fixture"

class TftpBoundaryTest < Minitest::Test
  def build(vendor, *events)
    Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: ConnectorFake.new(*events))
  end

  def test_receipt_requires_a_valid_path_or_an_unconfirmed_nil_path
    fields = { server: "192.0.2.10", completed_at: Time.now.utc }
    receipt = Net::Connector::TftpReceipt.new(**fields, path: nil)
    assert_nil receipt.path
    assert_equal :device_reported, receipt.verification
    verified = receipt.with(path: "backup.cfg", verification: :server_verified, server_sha256: "a" * 64)
    assert_equal "backup.cfg", verified.path
    assert_equal :server_verified, verified.verification
    assert_raises(ArgumentError) { receipt.with(archive_path: "/srv/tftp/archive/backup.cfg") }
    assert_equal "/srv/tftp/archive/backup.cfg", verified.with(archive_path: "/srv/tftp/archive/backup.cfg").archive_path

    [false, 0, "", "../backup.cfg"].each do |path|
      assert_raises(ArgumentError) { Net::Connector::TftpReceipt.new(**fields, path: path) }
      assert_raises(ArgumentError) { verified.with(path: path) }
    end
    assert_raises(ArgumentError) { verified.with(path: nil) }
  end

  def test_vendor_parameter_combinations_are_rejected_before_any_device_io
    invalid = {
      h3c: [{ vrf: "management" }, { path: false }, { source_file: false }, { vrf: false }],
      h3c_wireless: [{ vrf: "management" }],
      huawei: [{}, { source_file: "startup.cfg", vrf: "management" }],
      cisco_ios: [{ source_file: "startup.cfg" }, { vrf: "management" }],
      cisco_nxos: [{ source_file: "startup.cfg" }],
      hillstone: [{ source_file: "startup.cfg" }, { path: "site/file.dat" }],
      radware: [{ source_file: "startup.cfg" }, { vrf: "management" }],
      palo_alto: [{ source_file: "startup.cfg" }, { vrf: "management" }, { path: "other.xml" }]
    }
    invalid.each do |vendor, cases|
      cases.each do |options|
        device = build(vendor)
        assert_raises(ArgumentError, "#{vendor}: #{options.keys}") { device.tftp_backup(host: "192.0.2.10", **options) }
        transport = device.instance_variable_get(:@session).transport
        assert_equal 0, transport.opens
        assert_empty transport.writes
      ensure
        device&.close
      end
    end
  end

  def test_h3c_probe_and_transfer_share_one_lease_across_the_gap
    device = build(:h3c, "<H3C>")
    transport = device.instance_variable_get(:@session).transport
    transport.on_write = lambda do |bytes, _timeout|
      body = bytes.strip == "display startup" ? "Next main startup saved-configuration file: flash:/startup.cfg" : "Transfer complete."
      transport.events << "#{bytes}#{body}\n<H3C>"
    end
    original = device.method(:execute_command)
    checked, resume = Queue.new, Queue.new
    other_fiber = nil
    device.define_singleton_method(:execute_command) do |command, **options|
      result = original.call(command, **options)
      if command == "display startup"
        other_fiber = Fiber.new { original.call("other fiber") }.resume
        checked << true
        Timeout.timeout(3) { resume.pop }
      end
      result
    end
    uploading = Thread.new { device.tftp_backup(host: "192.0.2.10", path: "backup.cfg") }
    begin
      Timeout.timeout(3) { checked.pop }
      competing = original.call("other thread")
      assert_instance_of Net::Connector::SessionBusy, competing.error
      assert_instance_of Net::Connector::SessionBusy, other_fiber.error
      assert_equal ["display startup\n"], transport.writes
    ensure
      resume << true
      uploading.join(3) || uploading.kill.join
    end
    assert_equal "backup.cfg", uploading.value.path
    assert_equal ["display startup\n", "tftp 192.0.2.10 put flash:/startup.cfg backup.cfg\n"], transport.writes
  ensure
    device&.close
  end

  def test_successful_upload_survives_a_subsequent_logging_error_without_raw_diagnostics
    secret = "fixture-#{SecureRandom.hex(12)}"
    device = build(:hillstone, "fw#", "Export ok,target file name backup.dat\nfw#")
    device.define_singleton_method(:log_event) { |*_, **_options| raise IOError, secret }
    error = assert_raises(Net::Connector::Error) { device.tftp_backup(host: "192.0.2.10", path: "backup.dat") }
    assert_instance_of Net::Connector::TftpCompletionError, error
    assert_equal :transfer_finalize_failed, error.code
    assert_equal "backup.dat", error.receipt.path
    assert_equal :device_reported, error.receipt.verification
    assert_equal :startup, error.receipt.configuration_kind
    assert_equal :dat, error.receipt.format
    assert_equal "IOError", error.underlying_type
    assert_empty error.output
    assert_nil error.cause
    refute_includes error.full_message, secret
    refute_includes error.inspect, secret
    device.instance_variable_get(:@session).transport.events << "status ready\nfw#"
    assert device.execute_command("show status").success?, "lease must be released after event failure"
  ensure
    device&.close
  end

  def test_single_receipt_contains_the_real_configuration_kind_and_frozen_target
    expected = { cisco_ios: [:running, :cfg], cisco_nxos: [:running, :cfg], h3c: [:saved_file, :unknown],
                 huawei: [:saved_file, :unknown], hillstone: [:startup, :dat], palo_alto: [:running, :xml],
                 radware: [:native_archive, :tgz] }
    TftpFixture::CASES.each do |vendor, (prompt, command, output, path)|
      device = build(vendor, prompt, "#{command}\n#{output}\n#{prompt}")
      options = { host: "192.0.2.10", path: path }
      options[:source_file] = "startup.cfg" if %i[h3c huawei].include?(vendor)
      receipt = device.tftp_backup(**options)
      assert_instance_of Net::Connector::TftpReceipt, receipt
      assert_equal expected.fetch(vendor), [receipt.configuration_kind, receipt.format]
      assert_equal :device_reported, receipt.verification
      assert_nil receipt.server_sha256
      assert_equal path, receipt.requested_path
      assert_equal path, receipt.path
      assert receipt.frozen?
      assert receipt.path.frozen?
    ensure
      device&.close
    end
  end

  def test_explicit_path_mismatch_retains_the_actual_uploaded_file
    device = build(:hillstone, "fw#", "Export ok,target file name actual.dat\nfw#")
    error = assert_raises(Net::Connector::Error) { device.tftp_backup(host: "192.0.2.10", path: "requested.dat") }
    assert_instance_of Net::Connector::TftpCompletionError, error
    assert_equal :transfer_path_mismatch, error.code
    assert_equal "actual.dat", error.receipt.path
    assert_equal "requested.dat", error.receipt.requested_path
    assert_equal "actual.dat", error.receipt.path
    assert_equal :device_reported, error.receipt.verification
  ensure
    device&.close
  end

  def test_fleet_retains_confirmed_upload_when_event_logging_fails
    device = build(:hillstone, "fw#", "Export ok,target file name hillstone-192.0.2.1.dat\nfw#")
    device.define_singleton_method(:log_event) { |*_, **_options| raise IOError, "fixture event failure" }
    client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }])
    fleet = Net::Connector::Netdisco::Fleet.new(client: client, settings: Net::Connector::Netdisco::Settings.new(env: {}),
                                               credentials: ->(*) { { username: "audit" } },
                                               connector_factory: ->(*) { device }, result_store: nil)
    Dir.mktmpdir do |directory|
      batch = fleet.tftp_backup_all(server: "192.0.2.10", report_directory: directory)
      refute batch.success?
      assert_equal :reported_with_error, batch.outcomes.first.status
      assert_equal :transfer_finalize_failed, batch.outcomes.first.error_code
      assert_equal "hillstone-192.0.2.1.dat", batch.outcomes.first.backup.path
      assert_equal 1, batch.summary.fetch(:partial)
      assert_equal 0, batch.summary.fetch(:failed)
    end
  end

  def test_custom_script_explicitly_declares_its_options_and_metadata
    native = Net::Connector.vendor_class(:cisco_ios)
    strategy = Class.new(native.profile.tftp_strategy) do
      def validate_options!(_target, **) = nil
      def receipt_metadata(_target, **) = { configuration_kind: :unknown, format: :unknown }
      def script(_target, **_options) = Net::Connector::Script.new(["custom upload"])
      def device_reported_complete?(result) = result.output.include?("custom done")
    end
    klass = Class.new(native)
    klass.profile { tftp_strategy strategy }
    transport = ConnectorFake.new("router#", "custom done\nrouter#")
    device = klass.new(host: "192.0.2.1", username: "audit", transport: transport)
    receipt = device.tftp_backup(host: "192.0.2.10", path: "custom.cfg", source_file: "custom.cfg", vrf: "custom")
    assert_equal ["custom upload\n"], transport.writes
    assert_equal :unknown, receipt.configuration_kind
    assert_equal :unknown, receipt.format
    assert_equal "custom.cfg", receipt.source_file
    assert_equal :device_reported, receipt.verification
  ensure
    device&.close
  end

  def test_completed_upload_is_retained_when_command_cleanup_or_lease_cleanup_fails
    %i[command lease].each do |stage|
      secret = "fixture-#{SecureRandom.hex(12)}"
      device = build(:hillstone, "fw#", "Export ok,target file name backup.dat\nfw#")
      if stage == :command
        device.define_singleton_method(:after_command) { |*| raise IOError, secret }
      else
        original = device.method(:with_operation)
        device.define_singleton_method(:with_operation) do |name, &block|
          original.call(name, &block)
          raise IOError, secret
        end
      end
      error = assert_raises(Net::Connector::TftpCompletionError) do
        device.tftp_backup(host: "192.0.2.10", path: "backup.dat")
      end
      assert_equal :transfer_finalize_failed, error.code
      assert_equal "backup.dat", error.receipt.path
      assert_equal "IOError", error.underlying_type
      assert_nil error.cause
      assert_empty error.output
      refute_includes error.full_message, secret
      assert_equal 1, device.instance_variable_get(:@session).transport.writes.size
    ensure
      device&.close
    end
  end

  def test_bad_actual_filename_preserves_completion_without_inventing_the_requested_path
    device = build(:hillstone, "fw#", "Export ok,target file name ../unsafe.dat\nfw#")
    error = assert_raises(Net::Connector::TftpCompletionError) do
      device.tftp_backup(host: "192.0.2.10", path: "requested.dat")
    end
    assert_equal :transfer_path_unconfirmed, error.code
    assert_equal :device_reported, error.receipt.verification
    assert_equal "requested.dat", error.receipt.requested_path
    assert_nil error.receipt.path
    assert_nil error.receipt.path
    refute_includes error.full_message, "../unsafe.dat"
  ensure
    device&.close
  end

  def test_automatic_h3c_source_is_startup_and_input_strings_cannot_change_during_the_probe
    server, path, vrf = +"192.0.2.10", +"backup.cfg", +"management"
    device = build(:h3c, "<H3C>")
    transport = device.instance_variable_get(:@session).transport
    transport.on_write = lambda do |bytes, _timeout|
      if bytes.start_with?("display startup")
        server.replace("bad;host")
        path.replace("../bad")
        transport.events << "Next main startup saved-configuration file: flash:/startup.cfg\n<H3C>"
      else
        transport.events << "Transfer complete.\n<H3C>"
      end
    end
    receipt = device.tftp_backup(host: server, path: path)
    assert_equal :startup, receipt.configuration_kind
    assert_equal "flash:/startup.cfg", receipt.source_file
    assert_equal :unknown, receipt.format
    assert_equal "192.0.2.10", receipt.server
    assert_equal "backup.cfg", receipt.path
    assert_equal "tftp 192.0.2.10 put flash:/startup.cfg backup.cfg\n", transport.writes.last
    device.close

    device = build(:cisco_nxos, "switch#", "Copy complete\nswitch#")
    transport = device.instance_variable_get(:@session).transport
    transport.on_write = ->(*) { vrf.replace("bad;vrf") }
    receipt = device.tftp_backup(host: "192.0.2.10", path: "backup.cfg", vrf: vrf)
    assert_equal "copy running-config tftp://192.0.2.10/backup.cfg vrf management\n", transport.writes.last
    assert_equal :running, receipt.configuration_kind
  ensure
    device&.close
  end

  def test_device_generated_name_is_distinct_from_an_explicit_request
    device = build(:hillstone, "fw#", "Export ok,target file name generated.dat\nfw#")
    receipt = device.tftp_backup(host: "192.0.2.10")
    assert_nil receipt.requested_path
    assert_equal "generated.dat", receipt.path
    assert_equal :startup, receipt.configuration_kind
    assert_equal :dat, receipt.format
  ensure
    device&.close
  end

  def test_receipt_hook_failure_keeps_actual_completion_and_cannot_claim_server_verification
    %i[raises forged_verification].each do |behavior|
      secret = "fixture-#{SecureRandom.hex(12)}"
      native = Net::Connector.vendor_class(:hillstone)
      strategy = Class.new(native.profile.tftp_strategy) do
        define_method(:receipt_metadata) do |*, **|
          raise IOError, secret if behavior == :raises

          { verification: :server_verified, server_sha256: "a" * 64 }
        end
      end
      klass = Class.new(native)
      klass.profile { tftp_strategy strategy }
      device = klass.new(host: "192.0.2.1", username: "audit",
                         transport: ConnectorFake.new("fw#", "Export ok,target file name backup.dat\nfw#"))
      error = assert_raises(Net::Connector::TftpCompletionError) do
        device.tftp_backup(host: "192.0.2.10", path: "backup.dat")
      end
      assert_equal "backup.dat", error.receipt.path
      assert_equal :device_reported, error.receipt.verification
      assert_nil error.receipt.server_sha256
      refute_includes error.full_message, secret
    ensure
      device&.close
    end
  end

  def test_fleet_does_not_trust_third_party_or_subclass_completion_errors
    receipt = Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: "forged.dat", completed_at: Time.now.utc)
    errors = [Class.new(StandardError) { attr_accessor :receipt }.new("third party"),
              Class.new(Net::Connector::TftpCompletionError).new(receipt: receipt)]
    errors.first.receipt = receipt
    client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }])
    errors.each do |error|
      connector = Object.new
      connector.define_singleton_method(:tftp_backup) { |**| raise error }
      connector.define_singleton_method(:close) {}
      fleet = Net::Connector::Netdisco::Fleet.new(client: client, settings: Net::Connector::Netdisco::Settings.new(env: {}),
                                                 credentials: ->(*) { { username: "audit" } },
                                                 connector_factory: ->(*) { connector }, result_store: nil)
      Dir.mktmpdir do |directory|
        outcome = fleet.tftp_backup_all(server: "192.0.2.10", report_directory: directory).outcomes.first
        assert_equal :failed, outcome.status
        assert_nil outcome.backup
      end
    end
  end
end
