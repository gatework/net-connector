# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require_relative "../lib/net/connector"
require_relative "support/topology_fixture"

class InterfaceCollectionTest < Minitest::Test
  def setup
    @fixture = TopologyFixture.new(:cisco_ios)
  end

  def teardown
    @resume << true if @resume
    if @planning
      @planning.join(3)
      raise "interface planning thread did not finish" if @planning.alive?
    end
    @fixture.close
  end

  # 取得业务对象不连接设备；读取操作仍使用所属设备的真实采集与解析流程。
  def test_resource_access_is_offline_and_reads_neighbors_and_descriptions
    collection = interfaces
    assert_same collection, @fixture.device.interfaces
    refute @fixture.device.connected?
    assert_empty @fixture.observed

    assert_equal "peer", collection.neighbors.fetch(0).neighbor_name
    assert_equal({ "gigabitethernet1/0/1" => "original" }, collection.descriptions)
  end

  # 对象可以长期复用，现场证据必须在每次操作中重新读取。
  def test_reused_resource_replans_from_current_evidence_and_rejects_stale_plan
    collection = interfaces
    original = collection.plan { "planned" }
    @fixture.description = "changed outside this session"
    refreshed = collection.plan { "planned" }

    assert_equal "original", original.changes.fetch(0).old_description
    assert_equal "changed outside this session", refreshed.changes.fetch(0).old_description
    error = assert_raises(Net::Connector::DeviceError) { collection.apply(original, confirmed: true) }
    assert_equal :stale_plan, error.code
    refute_includes @fixture.observed.map(&:first), "configure terminal"
    assert collection.apply(refreshed, confirmed: true).success?
    assert_equal "planned", @fixture.description
  end

  def test_plan_and_audit_are_read_only_and_apply_requires_confirmation
    collection = interfaces
    plan = collection.plan { "planned" }
    audit = collection.audit { "planned" }

    assert_equal "planned", plan.changes.fetch(0).new_description
    assert_equal "planned", audit.plan.changes.fetch(0).new_description
    assert audit.complete?
    error = assert_raises(Net::Connector::UnsupportedOperation) { collection.apply(plan) }
    assert_equal :confirmation_required, error.code
    refute_includes @fixture.observed.map(&:first), "configure terminal"
    refute_includes @fixture.observed.map(&:first), @fixture.sample.fetch(:save)
  end

  def test_all_planning_actions_reject_invalid_format_options_before_device_io
    collection = interfaces
    %i[plan audit sync].each do |action|
      [{ abbreviate: nil }, { lowercase: "true" }].each do |options|
        assert_raises(ArgumentError) { collection.public_send(action, **options) { "planned" } }
      end
    end
    assert_empty @fixture.observed
    refute @fixture.device.connected?
  end

  # 两次采集之间也持有租约，避免同一设备的其他调用插入规划快照。
  def test_plan_holds_the_device_lease_between_neighbor_and_description_reads
    collection = interfaces
    discovered = Queue.new
    @resume = Queue.new
    resume = @resume
    read_neighbors = collection.method(:neighbors)
    collection.define_singleton_method(:neighbors) do
      value = read_neighbors.call
      discovered << true
      Timeout.timeout(3) { resume.pop }
      value
    end
    @planning = Thread.new { collection.plan { "planned" } }
    @planning.report_on_exception = false
    Timeout.timeout(3) { discovered.pop }

    concurrent = @fixture.device.execute_command("description concurrent")
    @resume << true
    Timeout.timeout(3) { @planning.join }

    assert_instance_of Net::Connector::SessionBusy, concurrent.error
    refute_includes @fixture.observed.map(&:first), "description concurrent"
    assert_equal "original", @planning.value.changes.fetch(0).old_description
    assert @fixture.device.execute_command("show version").success?
  end

  def test_formatter_failure_releases_the_planning_lease
    collection = interfaces
    assert_raises(ArgumentError) { collection.plan { "unsafe\nreload" } }
    assert @fixture.device.execute_command("show version").success?
    refute_includes @fixture.observed.map(&:first), "configure terminal"
  end

  def test_sync_can_plan_inside_its_lease_and_does_not_resave_matching_descriptions
    collection = interfaces
    assert collection.sync { "planned" }.success?
    assert_equal "planned", @fixture.description
    saved = @fixture.observed.count { |command, _| command == @fixture.sample.fetch(:save) }
    assert_equal 1, saved

    result = collection.sync { "planned" }
    assert result.success?
    assert_empty result.steps
    assert_equal 1, (@fixture.observed.count { |command, _| command == @fixture.sample.fetch(:save) })
  end

  private

  def interfaces
    assert_respond_to @fixture.device, :interfaces, "device must expose the interface collection"
    @fixture.device.interfaces
  end
end
