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

  def test_unknown_neighbor_names_and_ports_are_reported_without_commands
    ["-", "--", "n/a", "N/A", "unknown", "Unknown", "null", "none", " "].each do |value|
      [:neighbor_name, :neighbor_interface].each do |field|
        fixture = TopologyFixture.new(:h3c)
        topology = C::Topology.new(fixture.device)
        peer = C::Topology::Neighbor.new(local_interface: "GE1/0/1", neighbor_name: "peer", neighbor_interface: "GE1/0/2",
                                        chassis_id: "000f-e25d-ee91", protocol: :lldp).with(**{ field => value })
        audit = topology.stub(:neighbors, [peer]) do
          topology.stub(:interface_descriptions, { "gigabitethernet1/0/1" => "existing description" }) do
            topology.audit_interface_descriptions
          end
        end
        assert_equal :unverified, audit.comparisons.first.fetch(:status), "#{field}=#{value.inspect}"
        assert_nil audit.comparisons.first.fetch(:expected)
        assert_equal([field == :neighbor_name ? :unknown_neighbor_name : :unknown_neighbor_interface], audit.issues.map { |issue| issue.fetch(:code) })
        assert_empty audit.plan.changes
        assert_empty audit.plan.commands
        assert_empty audit.plan.evidence
      ensure
        fixture&.close
      end
    end
  end

  def test_unknown_interface_does_not_block_a_verified_uplink
    sample = TopologyFixture::SAMPLES.fetch(:h3c)
    fixture = TopologyFixture.new(:h3c, neighbor: sample.fetch(:neighbor) + "GE1/0/2 000f-e25d-ee92 000f-e25d-ee92 -\n")
    audit = fixture.device.audit_interface_descriptions
    assert_equal([:unknown_neighbor_name], audit.issues.map { |issue| issue.fetch(:code) })
    assert_equal [sample.fetch(:interface)], audit.plan.changes.map(&:interface)
    result = fixture.device.apply_interface_descriptions(audit.plan, confirmed: true)
    assert result.success?, result.error.inspect
    assert_equal "To_peer_Gi1/0/2", fixture.description
    refute(fixture.observed.any? { |command, _| command.include?("To_-_") })
  ensure
    fixture&.close
  end

  def test_direct_planning_sync_and_apply_cannot_bypass_unknown_neighbor_identity
    neighbor = "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 000f-e25d-ee91 -\n"
    [:plan_interface_descriptions, :sync_interface_descriptions].each do |operation|
      fixture = TopologyFixture.new(:h3c, neighbor: neighbor)
      error = assert_raises(C::ParsingError) { fixture.device.public_send(operation) }
      assert_equal :unknown_neighbor_name, error.code
      refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:enter) })
    ensure
      fixture&.close
    end
    fixture = TopologyFixture.new(:h3c)
    plan = fixture.device.plan_interface_descriptions
    fixture.sample[:neighbor] = neighbor
    error = assert_raises(C::ParsingError) { fixture.device.apply_interface_descriptions(plan, confirmed: true) }
    assert_equal :unknown_neighbor_name, error.code
    refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:enter) })
  ensure
    fixture&.close
  end

  def test_known_endpoint_with_mac_port_id_remains_valid_discovery_evidence
    fixture = TopologyFixture.new(:h3c, neighbor: "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 000f-e25d-ee92 phone\n")
    audit = fixture.device.audit_interface_descriptions
    assert audit.complete?
    assert_equal "To_phone_000f-e25d-ee92", audit.plan.changes.first.new_description
  ensure
    fixture&.close
  end

  def test_semantically_equal_descriptions_are_preserved_by_audit_plan_and_sync
    ["TO_peer_G1/0/2", "to_PEER_GE1/0/2", "To_peer_GigabitEthernet1/0/2"].each do |description|
      fixture = TopologyFixture.new(:h3c)
      fixture.description = description
      audit = fixture.device.audit_interface_descriptions
      assert_equal :matches, audit.comparisons.first.fetch(:status)
      assert_empty audit.plan.changes
      assert_empty fixture.device.plan_interface_descriptions.changes
      assert fixture.device.sync_interface_descriptions.success?
      assert_equal description, fixture.description
      refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:enter) })
    ensure
      fixture&.close
    end
  end

  def test_changed_peer_port_and_speed_are_not_treated_as_cosmetic_differences
    ["TO_other_G1/0/2", "TO_peer_G1/0/3", "TO_peer_XGE1/0/2", "TO_peer_G1/0/2.1"].each do |description|
      fixture = TopologyFixture.new(:h3c)
      fixture.description = description
      audit = fixture.device.audit_interface_descriptions
      assert_equal :content_mismatch, audit.comparisons.first.fetch(:status)
      assert_equal 1, audit.plan.changes.size
    ensure
      fixture&.close
    end
  end

end
