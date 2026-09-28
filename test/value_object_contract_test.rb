# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"

# 固定当前复制边界供兼容性重构使用；浅层共享不代表建议调用方修改回执。
class ValueObjectContractTest < Minitest::Test
  Connector = Net::Connector
  Netdisco = Connector::Netdisco

  def test_backup_constructor_preserves_member_references
    path = +"backup.cfg"
    sha256 = +"digest"
    collected_at = Time.utc(2026, 1, 1)
    backup = Connector::Backup.new(path: path, bytes: 1, sha256: sha256, collected_at: collected_at)

    path.replace("renamed.cfg")
    sha256.replace("changed")
    collected_at.localtime(3600)
    assert backup.frozen?
    assert_equal "renamed.cfg", backup.path
    assert_equal "changed", backup.sha256
    assert_equal 3600, backup.collected_at.utc_offset
  end

  def test_tftp_constructor_and_with_copy_and_freeze_supplied_fields
    original = Connector::TftpReceipt.new(server: "192.0.2.10", path: "backup.cfg", completed_at: Time.utc(2026, 1, 1))
    [->(fields) { Connector::TftpReceipt.new(**fields) }, ->(fields) { original.with(**fields) }].each do |build|
      fields = { server: +"192.0.2.10", path: +"backup.cfg", requested_path: +"backup.cfg",
                 source_file: +"startup.cfg", completed_at: Time.utc(2026, 1, 1) }
      receipt = build.call(fields)
      fields.each do |name, value|
        assert receipt.public_send(name).frozen?, name.to_s
        refute_same value, receipt.public_send(name)
        value.is_a?(Time) ? value.localtime(3600) : value.replace("changed")
      end
      assert_equal "192.0.2.10", receipt.server
      assert_equal "backup.cfg", receipt.path
      assert_equal "backup.cfg", receipt.requested_path
      assert_equal "startup.cfg", receipt.source_file
      assert_equal 0, receipt.completed_at.utc_offset
    end
    assert_raises(ArgumentError) { original.with(completed_at: nil) }
  end

  def test_file_receipt_constructor_copies_and_freezes_path
    path = +"backup.cfg"
    receipt = Connector::Storage::PrivateFile::Receipt.new(path: path, state: :committed, phase: :directory_sync)
    path.replace("changed.cfg")

    assert receipt.frozen?
    assert receipt.path.frozen?
    assert_equal "backup.cfg", receipt.path
    assert receipt.committed?
    refute receipt.durable?
  end

  def test_outcome_constructor_preserves_supplied_time_and_text_references
    error_type = +"IOError"
    started_at = Time.utc(2026, 1, 1)
    outcome = build_outcome(error_type: error_type, started_at: started_at)
    error_type.replace("RuntimeError")
    started_at.localtime(3600)

    assert outcome.frozen?
    assert_equal "RuntimeError", outcome.error_type
    assert_equal 3600, outcome.started_at.utc_offset
  end

  def test_outcome_with_invalidates_derived_fields_and_respects_explicit_replacements
    diagnostic = Netdisco::Diagnostic.new(error_type: "IOError")
    replacement = Netdisco::Diagnostic.new(error_type: "RuntimeError")
    outcome = build_outcome(duration_ms: 10, diagnostic: diagnostic)

    assert_same outcome, outcome.with
    %i[started_at finished_at].each do |field|
      assert_nil outcome.with(**{ field => Time.utc(2026, 1, 1) }).duration_ms
      assert_equal 20, outcome.with(**{ field => Time.utc(2026, 1, 1) }, duration_ms: 20).duration_ms
    end
    { error_code: :command_failed, error_type: "RuntimeError" }.each do |field, value|
      assert_nil outcome.with(**{ field => value }).diagnostic
      assert_same replacement, outcome.with(**{ field => value }, diagnostic: replacement).diagnostic
    end
    unchanged = outcome.with(status: :saved_with_error)
    assert_equal 10, unchanged.duration_ms
    assert_same diagnostic, unchanged.diagnostic
    assert_nil outcome.with(error_type: nil, diagnostic: nil).diagnostic
  end

  def test_batch_constructor_does_not_deep_freeze_caller_collections
    outcomes = []
    callback_error = { host: +"192.0.2.1", error_type: "IOError" }
    callback_errors = [callback_error]
    started_at = Time.utc(2026, 1, 1)
    batch = Netdisco::Batch.new(mode: :backup, outcomes: outcomes, callback_errors: callback_errors,
                               started_at: started_at, finished_at: nil, report_location: nil, report_error: nil)
    outcomes << build_outcome
    callback_error[:host].replace("192.0.2.2")
    started_at.localtime(3600)

    assert batch.frozen?
    assert_equal 1, batch.outcomes.size
    assert_equal "192.0.2.2", batch.callback_errors.first.fetch(:host)
    assert_equal 3600, batch.started_at.utc_offset
  end

  def test_direct_topology_plan_construction_preserves_member_references
    host = +"192.0.2.1"
    evidence = {}
    changes = []
    commands = []
    plan = Connector::Topology::Plan.new(host: host, vendor: :cisco_ios, evidence: evidence,
                                         changes: changes, commands: commands)
    host.replace("192.0.2.2")
    evidence["GigabitEthernet1/0/1"] = ["peer", "port", "description"]
    commands << "show running-config"

    assert plan.frozen?
    assert_equal "192.0.2.2", plan.host
    assert_same evidence, plan.evidence
    assert_equal 1, plan.evidence.size
    assert_same changes, plan.changes
    assert_equal ["show running-config"], plan.commands
  end

  private

  def build_outcome(**attributes)
    Netdisco::Outcome.new(device: nil, status: :failed, backup: nil, error_code: nil, error_type: nil, **attributes)
  end
end
