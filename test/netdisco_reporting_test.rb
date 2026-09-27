# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "securerandom"
require_relative "../lib/net/connector/netdisco"

class NetdiscoReportingTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  SUMMARY_KEYS = %i[mode status started_at finished_at total succeeded partial failed skipped counts callback_errors devices].freeze
  DEVICE_KEYS = %i[host name vendor status path bytes sha256 change previous_sha256 started_at finished_at duration_ms error_code error_type].freeze

  def device(index = 1)
    Netdisco::Device.from_row({ "ip" => "192.0.2.#{index}", "vendor" => "H3C" }, rules: Netdisco::Rules.new)
  end

  def batch(*statuses, callback_errors: [], report_error: nil)
    outcomes = statuses.each_with_index.map do |status, index|
      Netdisco::Outcome.new(device: device(index + 1), status: status, backup: nil, error_code: nil, error_type: nil)
    end
    Netdisco::Batch.new(mode: :backup, outcomes: outcomes, started_at: Time.now.utc, finished_at: Time.now.utc,
                        callback_errors: callback_errors, report_location: nil, report_error: report_error)
  end

  def test_selected_policy_allows_only_filtered_or_sampled_skips_and_requires_successful_work
    [[], [:filtered], [:sample_limit], [:filtered, :sample_limit]].each do |statuses|
      refute batch(*statuses).report(policy: :selected).policy_success?, statuses.inspect
    end
    %i[backed_up reported_uploaded].each do |success|
      value = batch(success, :filtered, :sample_limit)
      report = value.report(policy: :selected)
      refute value.success?
      refute report.success?
      assert report.policy_success?
      assert_equal :selected, report.policy
      assert_equal :incomplete, report.status
      assert_equal({ complete: false, attempted: 1, skipped: 2 }, report.summary.fetch(:coverage))
      assert_equal true, report.summary.fetch(:policy_success)
      assert_equal 2, report.summary.fetch(:schema_version)
      %i[failed saved_with_error reported_with_error duplicate_host invalid_address missing_credentials
         remote_filename_collision unsupported_vendor unexpected].each do |blocking|
        refute batch(success, blocking).report(policy: :selected).policy_success?, blocking.to_s
      end
      refute batch(success, callback_errors: [{ host: "192.0.2.1", error_type: "IOError" }])
             .report(policy: :selected).policy_success?
      refute batch(success, report_error: "IOError").report(policy: :selected).policy_success?
      assert batch(success).report(policy: :strict).policy_success?
      refute value.report(policy: :strict).policy_success?
    end
    assert_raises(ArgumentError) { batch(:backed_up).report(policy: :unknown) }
  end

  def test_legacy_data_members_positional_construction_and_default_report_keys_are_unchanged
    original = batch(:backed_up)
    assert_equal %i[mode outcomes started_at finished_at callback_errors report_location report_error], Netdisco::Batch.members
    assert_equal %i[device status backup error_code error_type started_at finished_at], Netdisco::Outcome.members
    assert_equal original, Netdisco::Batch.new(*original.deconstruct)
    assert_equal original.outcomes.first, Netdisco::Outcome.new(*original.outcomes.first.deconstruct)
    assert_equal SUMMARY_KEYS, original.summary.keys
    assert_equal DEVICE_KEYS, original.summary.fetch(:devices).first.keys
    assert_equal original.to_h, original.report.batch.to_h
  end

  def test_cli_selected_is_opt_in_and_reports_coverage_without_changing_the_old_status
    Dir.mktmpdir do |directory|
      [%w[], %w[--success-policy strict], %w[--success-policy selected], %w[--report-schema 2]].each do |extra|
        calls = []
        output, error = StringIO.new, StringIO.new
        factory = ->(settings) { fleet(settings: settings, calls: calls) }
        status = Netdisco::CLI.new(argv: ["--tftp", "--host", "192.0.2.1", *extra],
                                   env: { "TFTP_HOST" => "192.0.2.10", "NET_CONNECTOR_BACKUP_DIRECTORY" => directory },
                                   output: output, error: error, fleet_factory: factory).run
        selected = extra.include?("selected")
        assert_equal selected ? 0 : 1, status, error.string
        assert_equal ["192.0.2.1"], calls
        document = JSON.parse(output.string)
        assert_equal "incomplete", document.fetch("status")
        assert_equal 1, document.fetch("skipped")
        if selected || extra.include?("2")
          assert_equal 2, document.fetch("schema_version")
          assert_equal selected ? "selected" : "strict", document.fetch("policy")
          assert_equal selected, document.fetch("policy_success")
          refute document.fetch("coverage").fetch("complete")
        else
          assert_equal (SUMMARY_KEYS + %i[report_location report_error]).map(&:to_s), document.keys
        end
      end
    end
  end

  def test_invalid_reporting_options_fail_before_inventory_or_device_io
    [%w[--success-policy unknown], %w[--report-schema 3],
     %w[--success-policy selected --report-schema 1]].each do |argv|
      calls = []
      status = Netdisco::CLI.new(argv: argv, env: {}, output: StringIO.new, error: StringIO.new,
                                 fleet_factory: ->(*) { calls << true }).run
      assert_equal 2, status
      assert_empty calls
    end
    client = Object.new
    client.define_singleton_method(:devices) { flunk "invalid policy must not fetch inventory" }
    value = Netdisco::Fleet.new(client: client, result_store: nil)
    assert_raises(ArgumentError) { value.backup_all(success_policy: :unknown) }
    assert_raises(ArgumentError) { value.tftp_backup_all(server: "192.0.2.10", success_policy: :selected, report_schema: 1) }
    [false, 1.0, -1, "2", 0, []].each do |schema|
      assert_raises(ArgumentError) { value.backup_all(report_schema: schema) }
    end
  end

  def test_v2_diagnostics_keep_known_fields_but_never_serialize_arbitrary_error_context
    secret = "fixture_#{SecureRandom.hex(12)}"
    underlying = Net::Connector::UnderlyingError.new(IOError.new(secret), ->(text) { text })
    known = Net::Connector::DeviceError.new(secret, code: :incomplete_configuration, phase: :collect,
                                           command: secret, output: secret, source: secret, line: secret, underlying: underlying)
    forged = Net::Connector::DeviceError.new(secret, code: secret.to_sym, phase: secret,
                                            command: secret, output: secret, source: secret, line: secret)
    forged.define_singleton_method(:inspect) { raise "must not inspect exception" }
    forged.define_singleton_method(:to_h) { raise "must not serialize exception" }
    Dir.mktmpdir do |directory|
      [known, forged].each do |failure|
        report = fleet(error: failure, rows: [row(1)]).tftp_backup_all(server: "192.0.2.10", report_directory: directory,
                                                                     report_schema: 2)
        assert_instance_of Netdisco::Report, report
        document = report.summary
        entry = document.fetch(:devices).first
        assert_equal "Net::Connector::DeviceError", entry.fetch(:error_type)
        if failure.equal?(known)
          assert_equal :incomplete_configuration, entry.fetch(:error_code)
          assert_equal :collect, entry.fetch(:diagnostic).fetch(:phase)
          assert_equal "IOError", entry.fetch(:diagnostic).fetch(:underlying_type)
        else
          assert_nil entry.fetch(:error_code)
          assert_nil entry.fetch(:diagnostic).fetch(:phase)
        end
        refute_includes JSON.generate(document), secret
        refute_includes File.read(report.report_location), secret
      end
    end
  end

  def test_unknown_exception_names_and_callback_or_store_errors_cannot_expand_v2_diagnostics
    secret = "Fixture#{SecureRandom.hex(12)}"
    error_class = Class.new(StandardError)
    self.class.const_set(secret, error_class)
    failure = error_class.new(secret)
    callback = ->(*) { raise failure }
    store = Object.new
    store.define_singleton_method(:write) { |_, **| raise failure }
    Dir.mktmpdir do |directory|
      report = fleet(error: failure, rows: [row(1)], store: store)
               .tftp_backup_all(server: "192.0.2.10", report_directory: directory, on_result: callback,
                                success_policy: :selected)
      refute report.policy_success?
      document = report.summary
      assert_equal "StandardError", document.fetch(:devices).first.fetch(:error_type)
      assert_equal "StandardError", document.fetch(:callback_errors).first.fetch(:error_type)
      assert_equal "StandardError", document.fetch(:report_error)
      refute_includes JSON.generate(document), secret
    end
  ensure
    self.class.send(:remove_const, secret) if secret && self.class.const_defined?(secret, false)
  end

  def test_custom_result_store_retains_its_write_signature_for_both_schemas
    received = []
    store = Object.new
    store.define_singleton_method(:write) do |value, directory:|
      received << [value, directory, value.summary]
      "database:42"
    end
    Dir.mktmpdir do |directory|
      value = fleet(rows: [row(1)], store: store)
      old = value.tftp_backup_all(server: "192.0.2.10", report_directory: directory)
      report = value.tftp_backup_all(server: "192.0.2.10", report_directory: directory, report_schema: 2)
      assert_instance_of Netdisco::Batch, old
      assert_instance_of Netdisco::Batch, received.first.first
      assert_instance_of Netdisco::Report, received.last.first
      assert_equal [directory, directory], (received.map { |item| item[1] })
      assert_equal SUMMARY_KEYS, received.first.last.keys
      assert_equal 2, received.last.last.fetch(:schema_version)
      assert_equal "database:42", report.report_location
      assert report.policy_success?
    end
  end

  def test_worker_duration_uses_monotonic_time_even_when_audit_time_moves_backwards
    wall = Time.utc(2026, 9, 27, 12)
    clock = 10.0
    worker = Netdisco::Worker.new(concurrency: 1)
    outcomes = [nil]
    Time.stub(:now, -> { wall }) do
      worker.stub(:monotonic, -> { clock }) do
        worker.run([[0, device]], outcomes: outcomes, on_error: ->(*) { flunk "unexpected worker failure" }) do
          wall -= 30
          clock += 1.25
          batch(:backed_up).outcomes.first
        end
      end
    end
    outcome = outcomes.first
    assert_operator outcome.finished_at, :<, outcome.started_at
    assert_equal 1250, outcome.duration_ms
    assert_equal 1250, outcome.with(status: :saved_with_error).duration_ms
    assert_equal Netdisco::Outcome.members, outcome.to_h.keys
    assert_equal 7, outcome.deconstruct.size
  end

  def test_fleet_v2_duration_and_audit_times_remain_independent
    Dir.mktmpdir do |directory|
      wall = Time.utc(2026, 9, 27, 12)
      clock = 15.0
      value = fleet(rows: [row(1)], store: nil)
      report = Time.stub(:now, -> { wall }) do
        value.stub(:monotonic, -> { clock }) do
          value.tftp_backup_all(server: "192.0.2.10", report_directory: directory, report_schema: 2,
                                on_result: ->(*) { wall -= 60; clock += 2 })
        end
      end
      assert_operator report.finished_at, :<, report.started_at
      assert_equal 2000, report.duration_ms
      assert_equal 2000, report.summary.fetch(:duration_ms)
      assert_equal 2000, report.with(report_location: "database:1").duration_ms
      assert report.policy_success?
    end
  end

  def test_v2_typed_completion_errors_retain_artifact_phases_through_worker_metadata
    transfer = Net::Connector::TftpBackup.new(server: "192.0.2.10", path: "known.cfg", completed_at: Time.now.utc)
    receipt = Net::Connector::TftpReceipt.new(transfer: transfer, actual_path: transfer.path)
    failure = Net::Connector::TftpCompletionError.new(receipt: receipt, underlying: IOError.new("fixture finalization"))
    Dir.mktmpdir do |directory|
      calls = []
      report = fleet(rows: [row(1)], error: failure, calls: calls, store: nil)
               .tftp_backup_all(server: "192.0.2.10", report_directory: directory, success_policy: :selected)
      entry = report.summary.fetch(:devices).first
      assert_equal :reported_with_error, entry.fetch(:status)
      assert_equal "known.cfg", entry.fetch(:path)
      assert_equal :reported_uploaded, entry.fetch(:diagnostic).fetch(:artifact_state)
      assert_equal :finalize, entry.fetch(:diagnostic).fetch(:artifact_phase)
      assert_equal :device_reported, entry.fetch(:diagnostic).fetch(:verification)
      assert_equal "IOError", entry.fetch(:diagnostic).fetch(:underlying_type)
      refute report.policy_success?
      assert_equal ["192.0.2.1"], calls

      connector = Object.new
      connector.define_singleton_method(:backup) do |path:|
        backup = Net::Connector::Backup.new(path: path, bytes: 1, sha256: "fixture", collected_at: Time.now.utc)
        receipt = Net::Connector::Operations::PrivateFile::Receipt.new(path: path, state: :committed, phase: :directory_sync)
        error = Net::Connector::Operations::PrivateFile::PersistenceError.new(receipt: receipt, underlying_type: "IOError")
        raise Net::Connector::BackupPersistenceError.new(backup: backup, write_error: error), cause: nil
      end
      connector.define_singleton_method(:close) {}
      value = Netdisco::Fleet.new(client: Struct.new(:devices).new([row(1)]), result_store: nil,
                                  credentials: ->(*) { { username: "audit" } }, connector_factory: ->(*) { connector })
      report = value.backup_all(directory: directory, report_schema: 2)
      entry = report.summary.fetch(:devices).first
      assert_equal :saved_with_error, entry.fetch(:status)
      assert_equal :backup_persistence_unconfirmed, entry.fetch(:error_code)
      assert_equal :committed, entry.fetch(:diagnostic).fetch(:artifact_state)
      assert_equal :directory_sync, entry.fetch(:diagnostic).fetch(:artifact_phase)
      assert_equal "IOError", entry.fetch(:diagnostic).fetch(:underlying_type)
      refute report.policy_success?
    end
  end

  def test_successful_work_remains_unsuccessful_under_selected_when_callback_or_report_fails
    Dir.mktmpdir do |directory|
      %i[callback report].each do |stage|
        calls, writes = [], []
        store = Object.new
        store.define_singleton_method(:write) do |value, **|
          writes << value
          raise IOError, "fixture report failure" if stage == :report

          "database:42"
        end
        callback = ->(*) { raise IOError, "fixture callback failure" if stage == :callback }
        report = fleet(rows: [row(1)], calls: calls, store: store)
                 .tftp_backup_all(server: "192.0.2.10", report_directory: directory, success_policy: :selected,
                                  on_result: callback)
        refute report.policy_success?
        assert_equal :reported_uploaded, report.outcomes.first.status
        assert_equal ["192.0.2.1"], calls
        assert_equal 1, writes.size
        assert report.summary.fetch(:coverage).fetch(:complete)
      end
    end
  end

  def test_v2_report_write_receipt_retains_commit_state_without_claiming_device_completion
    Dir.mktmpdir do |directory|
      path = File.join(directory, "report.json")
      receipt = Net::Connector::Operations::PrivateFile::Receipt.new(path: path, state: :committed, phase: :directory_sync)
      failure = Net::Connector::Operations::PrivateFile::PersistenceError.new(receipt: receipt, underlying_type: "IOError")
      store = Object.new
      store.define_singleton_method(:write) { |_, **| raise failure }
      report = fleet(rows: [row(1)], store: store)
               .tftp_backup_all(server: "192.0.2.10", report_directory: directory, success_policy: :selected)
      assert_equal path, report.report_location
      refute report.policy_success?
      diagnostic = report.summary.fetch(:report_diagnostic)
      assert_equal :report, diagnostic.fetch(:phase)
      assert_equal :committed, diagnostic.fetch(:artifact_state)
      assert_equal :directory_sync, diagnostic.fetch(:artifact_phase)

      report = fleet(rows: [row(1)], error: failure, store: nil)
               .tftp_backup_all(server: "192.0.2.10", report_directory: directory, report_schema: 2)
      entry = report.summary.fetch(:devices).first
      assert_equal :failed, entry.fetch(:status)
      assert_nil entry.fetch(:path)
      assert_nil entry.fetch(:diagnostic).fetch(:artifact_state)
    end
  end

  def test_default_cli_still_accepts_a_fleet_with_the_old_keyword_signature
    value = batch(:backed_up)
    fake = Object.new
    fake.define_singleton_method(:plan_backup) { |limit_per_vendor:| limit_per_vendor }
    fake.define_singleton_method(:backup_all) { |plan:, directory:, concurrency:| value if plan.nil? && directory && concurrency }
    output = StringIO.new
    result = Netdisco::CLI.new(argv: [], env: {}, output: output, error: StringIO.new,
                               fleet_factory: ->(*) { fake }).run
    assert_equal 0, result
    assert_equal (SUMMARY_KEYS + %i[report_location report_error]).map(&:to_s), JSON.parse(output.string).keys
  end

  def test_v2_revalidates_manually_changed_error_fields_without_mutating_legacy_data
    secret = "fixture_#{SecureRandom.hex(12)}"
    diagnostic = Netdisco::Diagnostic.new(error_code: :incomplete_configuration, error_type: "Net::Connector::DeviceError", phase: :collect)
    original = batch(:failed)
    outcome = original.outcomes.first.with(diagnostic: diagnostic).with(error_code: secret.to_sym, error_type: secret)
    assert_nil outcome.diagnostic
    value = original.with(outcomes: [outcome], report_error: secret)
    document = value.report.summary
    refute_includes JSON.generate(document), secret
    assert_nil document.fetch(:devices).first.fetch(:error_code)
    assert_equal "StandardError", document.fetch(:devices).first.fetch(:error_type)
    assert_equal "StandardError", document.fetch(:report_error)
    assert_equal secret, value.report_error
  end

  private

  def row(index) = { "ip" => "192.0.2.#{index}", "vendor" => "H3C" }

  def fleet(settings: Netdisco::Settings.new(env: {}), calls: [], rows: [row(1), row(2)], error: nil,
            store: Netdisco::ResultStore::Text.new)
    factory = lambda do |device, _options|
      connector = Object.new
      connector.define_singleton_method(:tftp_backup) do |**options|
        calls << device.host
        raise error if error

        Net::Connector::TftpBackup.new(server: options.fetch(:host), path: options.fetch(:path), completed_at: Time.now.utc)
      end
      connector.define_singleton_method(:close) {}
      connector
    end
    Netdisco::Fleet.new(settings: settings, client: Struct.new(:devices).new(rows),
                        credentials: ->(*) { { username: "audit" } }, connector_factory: factory, result_store: store)
  end
end
