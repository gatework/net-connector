# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"

# 完成回执拥有自身元数据；原始批次容器的显式共享边界单独验证。
class ValueObjectContractTest < Minitest::Test
  Connector = Net::Connector
  Netdisco = Connector::Netdisco

  def test_device_updates_copy_and_freeze_external_strings
    original = Netdisco::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "H3C" }, rules: Netdisco::Rules.new)
    host = +"192.0.2.2"
    updated = original.with(host: host)
    host.replace("192.0.2.3")
    assert_equal "192.0.2.2", updated.host
    assert_predicate updated.host, :frozen?
    assert_equal "192.0.2.1", original.host
  end

  def test_plan_updates_copy_and_freeze_external_containers
    device = Netdisco::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "H3C" }, rules: Netdisco::Rules.new)
    original = Netdisco::Plan.new(mode: :backup, inventory: [device], ready: [[0, device]], outcomes: [nil])
    inventory, tasks, outcomes = [device], [[0, device]], [nil]
    updated = original.with(inventory: inventory, ready: tasks, outcomes: outcomes)
    inventory.clear
    tasks.first.clear
    tasks.clear
    outcomes.clear
    assert_same updated, updated.validate!
    assert_equal [device], updated.selected
    [updated.inventory, updated.ready, updated.ready.first, updated.outcomes].each { |value| assert_predicate value, :frozen? }
  end

  def test_file_receipt_updates_revalidate_and_copy_the_path
    original = Connector::Storage::AtomicFile::Receipt.new(path: "backup.cfg", state: :committed, phase: :directory_sync)
    path = +"updated.cfg"
    updated = original.with(path: path)
    path.replace("changed.cfg")
    assert_equal "updated.cfg", updated.path
    assert_predicate updated.path, :frozen?
    assert_raises(ArgumentError) { original.with(state: :unknown) }
    assert_raises(ArgumentError) { original.with(phase: :unknown) }
  end

  def test_diagnostic_updates_apply_the_same_white_list_as_construction
    original = Netdisco::Diagnostic.new(error_type: "IOError")
    values = { error_type: "private-value", underlying_type: "private-value", error_code: :private_value,
               phase: :private_value, artifact_state: :private_value, artifact_phase: :private_value, verification: :private_value }
    updated = original.with(**values)
    assert_equal Netdisco::Diagnostic.new(**values), updated
    refute_includes updated.to_h.to_json, "private"
  end

  def test_backup_constructor_owns_member_values
    path = +"backup.cfg"
    sha256 = +"digest"
    collected_at = Time.utc(2026, 1, 1)
    backup = Connector::Backup.new(path: path, bytes: 1, sha256: sha256, collected_at: collected_at)

    path.replace("renamed.cfg")
    sha256.replace("changed")
    collected_at.localtime(3600)
    assert backup.frozen?
    assert_equal "backup.cfg", backup.path
    assert_equal "digest", backup.sha256
    assert_equal 0, backup.collected_at.utc_offset
    [backup.path, backup.sha256, backup.collected_at].each { |value| assert_predicate value, :frozen? }
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
    receipt = Connector::Storage::AtomicFile::Receipt.new(path: path, state: :committed, phase: :directory_sync)
    path.replace("changed.cfg")

    assert receipt.frozen?
    assert receipt.path.frozen?
    assert_equal "backup.cfg", receipt.path
    assert receipt.committed?
    refute receipt.durable?
  end

  def test_outcome_constructor_owns_supplied_time_and_text_values
    error_type = +"IOError"
    started_at = Time.utc(2026, 1, 1)
    outcome = build_outcome(error_type: error_type, started_at: started_at)
    error_type.replace("RuntimeError")
    started_at.localtime(3600)

    assert outcome.frozen?
    assert_equal "IOError", outcome.error_type
    assert_equal 0, outcome.started_at.utc_offset
    assert_predicate outcome.error_type, :frozen?
    assert_predicate outcome.started_at, :frozen?
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

  def test_batch_owns_collections_and_audit_metadata_without_freezing_callers
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
    assert_empty batch.outcomes
    assert_equal "192.0.2.1", batch.callback_errors.first.fetch(:host)
    assert_equal 0, batch.started_at.utc_offset
    assert batch.outcomes.frozen?
    assert batch.callback_errors.first.fetch(:host).frozen?
  end

  def test_direct_topology_plan_construction_owns_member_snapshots
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
    assert_equal "192.0.2.1", plan.host
    assert_empty plan.evidence
    refute_same changes, plan.changes
    assert_empty plan.commands
    assert plan.evidence.frozen?
    assert plan.changes.frozen?
    assert plan.commands.frozen?
  end

  def test_topology_updates_own_nested_evidence_and_change_strings
    name = +"peer"
    neighbor = Connector::Topology::Neighbor.new(local_interface: +"Ethernet1", neighbor_name: name,
                                                 neighbor_interface: +"Ethernet2", chassis_id: +"chassis", protocol: :lldp)
    name.replace("changed")
    assert_equal "peer", neighbor.neighbor_name
    replacement = +"next-peer"
    updated_neighbor = neighbor.with(neighbor_name: replacement)
    replacement.clear
    assert_equal "next-peer", updated_neighbor.neighbor_name
    description = +"approved"
    change = Connector::Topology::Change.new(interface: +"Ethernet1", old_description: +"old",
                                              new_description: description, neighbor: neighbor)
    fields = [+"peer", +"Ethernet2", +"old"]
    commands = [+"show version"]
    plan = Connector::Topology::Plan.new(host: +"192.0.2.1", vendor: :cisco_ios,
                                          evidence: { "ethernet1" => fields }, changes: [change], commands: commands)
    description.clear
    fields.first.clear
    commands.first.clear
    assert_equal "approved", plan.changes.first.new_description
    assert_equal ["peer", "Ethernet2", "old"], plan.evidence.fetch("ethernet1")
    assert_equal ["show version"], plan.commands
    replacement = +"revised"
    changed = change.with(new_description: replacement)
    fields = [+"peer", +"Ethernet2", +"old"]
    updated = plan.with(evidence: { "ethernet1" => fields }, changes: [changed])
    replacement.clear
    fields.last.clear
    assert_equal "revised", updated.changes.first.new_description
    assert_equal "old", updated.evidence.fetch("ethernet1").last
    assert_raises(FrozenError) { updated.evidence.fetch("ethernet1").first.clear }
    assert_raises(ArgumentError) { plan.with(changes: [Object.new]) }
    assert_raises(ArgumentError) { plan.with(evidence: { "Ethernet1" => ["incomplete"] }) }
  end

  def test_batch_updates_recompute_counts_and_keep_independent_metadata
    started = Time.utc(2026, 1, 1)
    batch = Netdisco::Batch.new(mode: :backup, outcomes: [build_outcome], callback_errors: [],
                               started_at: started, finished_at: started, report_location: nil, report_error: nil)
    assert_raises(ArgumentError) { build_outcome(status: []) }
    status = +"unknown"
    unknown = batch.with(outcomes: [build_outcome(status: status)])
    status.clear
    assert_equal({ "unknown" => 1 }, unknown.counts)
    refute unknown.build_report(policy: :selected).policy_success?
    counts = batch.counts
    counts.clear
    assert_equal({ failed: 1 }, batch.counts)
    values = [build_outcome.with(status: :backed_up)]
    host = +"192.0.2.1"
    errors = [{ host: host, error_type: +"IOError" }]
    location = +"report.json"
    updated = batch.with(outcomes: values, callback_errors: errors, report_location: location)
    values.clear
    host.clear
    errors.clear
    location.clear
    assert_equal({ backed_up: 1 }, updated.counts)
    assert_equal "192.0.2.1", updated.callback_errors.first.fetch(:host)
    assert_equal "report.json", updated.report_location
    refute updated.success?
    assert updated.with(callback_errors: []).success?
    assert_equal({ failed: 1 }, batch.counts)
  end

  private

  def build_outcome(**attributes)
    Netdisco::Outcome.new(device: nil, status: :failed, backup: nil, error_code: nil, error_type: nil, **attributes)
  end
end
