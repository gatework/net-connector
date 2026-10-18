# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/net/connector"
require_relative "support/topology_fixture"

class TopologyAuditTest < Minitest::Test
  C = Net::Connector

  def test_updated_audit_revalidates_and_owns_its_rows
    original = C::Topology::Audit.new(plan: nil, comparisons: [], issues: [], manual_required: false)
    assert_same original, original.with
    assert_raises(ArgumentError) { original.with(manual_required: nil) }
    rows = [{ interface: +"Gi1", code: :ambiguous_neighbor }]
    updated = original.with(issues: rows)
    rows.first[:interface].replace("changed")
    rows.clear
    assert_equal "Gi1", updated.issues.first.fetch(:interface)
    assert updated.issues.first.fetch(:interface).frozen?
  end

  def test_ambiguous_interface_is_excluded_while_verified_interface_can_be_applied
    sample = TopologyFixture::SAMPLES.fetch(:h3c)
    neighbor = sample.fetch(:neighbor) + "GE1/0/2 000f-e25d-ee92 GE1/0/3 other\nGE1/0/2 000f-e25d-ee93 GE1/0/4 duplicate\n"
    fixture = TopologyFixture.new(:h3c, neighbor: neighbor)
    audit = fixture.device.audit_interface_descriptions
    assert_equal([:ambiguous_neighbor], audit.issues.map { |issue| issue.fetch(:code) })
    assert_equal :interfaces, audit.plan.scope
    assert_equal ["gigabitethernet1/0/1"], audit.plan.evidence.keys
    assert_equal [sample.fetch(:interface)], audit.plan.changes.map(&:interface)
    refute(fixture.observed.any? { |command, _| command.start_with?("description ") })
    # 其他接口仍有歧义；不能阻止已经核实、写入范围明确的接口。
    result = fixture.device.apply_interface_descriptions(audit.plan, confirmed: true)
    assert result.success?, result.error.inspect
    assert_equal "To_peer_Gi1/0/2", fixture.description
    assert_equal(1, fixture.observed.count { |command, _| command == sample.fetch(:save) })
    refute(fixture.observed.any? { |command, _| command == "interface GigabitEthernet1/0/2" })
  ensure
    fixture&.close
  end

  def test_scoped_plan_still_rejects_identity_changes_on_an_approved_interface
    fixture = TopologyFixture.new(:h3c)
    audit = fixture.device.audit_interface_descriptions
    neighbor = fixture.sample.fetch(:neighbor).sub("000f-e25d-ee91", "000f-e25d-ee92")
    fixture.sample[:neighbor] = neighbor
    error = assert_raises(C::DeviceError) { fixture.device.apply_interface_descriptions(audit.plan, confirmed: true) }
    assert_equal :stale_plan, error.code
    refute(fixture.observed.any? { |command, _| command.start_with?("description ") })
  ensure
    fixture&.close
  end

  def test_unsafe_formatter_is_reported_and_does_not_create_commands
    fixture = TopologyFixture.new(:h3c)
    audit = fixture.device.audit_interface_descriptions { |_neighbor| "unsafe; shutdown" }
    assert_equal([:unsafe_description], audit.issues.map { |issue| issue.fetch(:code) })
    assert_empty audit.plan.changes
    assert_empty audit.plan.commands
    assert audit.issues.frozen?
    assert audit.comparisons.frozen?
    assert_raises(FrozenError) { audit.issues.first[:interface].replace("other") }
  ensure
    fixture&.close
  end

  def test_formatter_runs_once_for_each_verified_interface
    fixture = TopologyFixture.new(:h3c)
    calls = []
    audit = fixture.device.audit_interface_descriptions do |neighbor|
      calls << neighbor
      "custom-description"
    end
    assert_equal 1, calls.size
    assert_equal "custom-description", audit.plan.changes.first.new_description
  ensure
    fixture&.close
  end

  def test_read_only_platform_reports_manual_changes_without_constructing_a_write_plan
    profile = C.vendor_class(:palo_alto).profile
    context = Struct.new(:host, :vendor, :profile) do
      def with_operation(_phase) = yield
    end.new("192.0.2.1", :palo_alto, profile)
    topology = C::Topology.new(context)
    peer = C::Topology::Neighbor.new(local_interface: "ethernet1/1", neighbor_name: "peer", neighbor_interface: "Ethernet1/2", chassis_id: "peer-chassis", protocol: :lldp)
    audit = topology.stub(:neighbors, [peer]) do
      topology.stub(:interface_descriptions, { "ethernet1/1" => "old" }) { topology.audit_interface_descriptions }
    end
    assert audit.complete?
    assert audit.manual_required
    assert_nil audit.plan
    assert_equal 1, audit.changes
    assert_equal "To_peer_Eth1/2", audit.comparisons.first.fetch(:expected)
  end

end
