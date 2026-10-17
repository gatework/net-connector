# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/net/connector/netdisco"
require_relative "support/topology_fixture"

class NetdiscoTopologyBatchTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  HOST = "192.0.2.1"

  # 整条 Fleet -> Operations -> 真正设备门面在合成对话上贯通，不代替现场固件验收。
  def test_planning_and_application_preserve_change_readback_save_order
    each_fleet do |fleet, fixtures|
      planned = fleet.plan_interface_descriptions(hosts: [HOST]) { "planned" }
      assert planned.success?
      assert fixtures.first.transport.closed?
      assert_equal(0, fixtures.first.observed.count { |command, _| command.start_with?("description ") })
      batch = fleet.apply_interface_descriptions(plans: planned.plans, confirmed: true)
      assert batch.success?, batch.to_h.inspect
      fixture = fixtures.last
      sent = fixture.observed
      changed = sent.index { |command, _| command == "description planned" }
      verified = sent.rindex { |command, _| command == fixture.sample.fetch(:collect) }
      saved = sent.index { |command, _| command == fixture.sample.fetch(:save) }
      assert_operator changed, :<, verified
      assert_operator verified, :<, saved
      assert_equal :exec, sent.fetch(verified).last
      assert_equal :exec, sent.fetch(saved).last
      assert_equal "planned", fixture.description
      assert_equal(planned.plans.fetch(HOST).commands, batch.outcomes.first.value.steps.map { |step| step.command.text })
      assert_equal 2, fixtures.size
      assert(fixtures.all? { |item| item.transport.closed? })
    end
  end

  def test_readback_mismatch_never_saves_and_keeps_completed_steps
    each_fleet(fault: :mismatch) do |fleet, fixtures|
      planned = fleet.plan_interface_descriptions(hosts: [HOST]) { "planned" }
      batch = fleet.apply_interface_descriptions(plans: planned.plans, confirmed: true)
      outcome = batch.outcomes.first
      assert outcome.partial?
      assert_equal :description_unconfirmed, outcome.error.code
      assert outcome.value.failure?
      assert_includes outcome.value.steps.map { |step| step.command.text }, "description planned"
      assert_equal(0, fixtures.last.observed.count { |command, _| command == fixtures.last.sample.fetch(:save) })
      assert_equal 2, fixtures.size
      assert fixtures.last.transport.closed?
    end
  end

  def test_unconfirmed_save_is_not_retried_and_summary_keeps_only_diagnostic_metadata
    each_fleet(fault: :save_unconfirmed) do |fleet, fixtures|
      planned = fleet.plan_interface_descriptions(hosts: [HOST]) { "planned" }
      batch = fleet.apply_interface_descriptions(plans: planned.plans, confirmed: true)
      outcome = batch.outcomes.first
      assert outcome.partial?
      assert_equal :persistence_unconfirmed, outcome.error.code
      assert_equal :persist, outcome.error.phase
      assert outcome.value.failure?
      assert_equal(1, fixtures.last.observed.count { |command, _| command == fixtures.last.sample.fetch(:save) })
      assert_equal 2, fixtures.size
      summary = JSON.generate(batch.to_h)
      refute_includes summary, "description planned"
      refute_includes summary, "private-password"
      assert fixtures.last.transport.closed?
    end
  end

  def test_stale_evidence_rejects_before_writing_and_does_not_retry
    each_fleet(fault: :stale) do |fleet, fixtures|
      planned = fleet.plan_interface_descriptions(hosts: [HOST]) { "planned" }
      batch = fleet.apply_interface_descriptions(plans: planned.plans, confirmed: true)
      outcome = batch.outcomes.first
      assert_equal :failed, outcome.status
      assert_equal :stale_plan, outcome.error.code
      assert_nil outcome.value
      assert_equal(0, fixtures.last.observed.count { |command, _| command.start_with?("description ") })
      assert_equal(0, fixtures.last.observed.count { |command, _| command == fixtures.last.sample.fetch(:enter) })
      assert_equal(0, fixtures.last.observed.count { |command, _| command == fixtures.last.sample.fetch(:save) })
      assert_equal 2, fixtures.size
      assert fixtures.last.transport.closed?
    end
  end

  def test_sync_uses_one_connection_and_publishes_one_final_result_per_device
    each_fleet do |fleet, fixtures|
      notified = []
      batch = fleet.sync_interface_descriptions(hosts: [HOST], on_result: ->(outcome) { notified << outcome })
      assert batch.success?, batch.to_h.inspect
      assert_equal :sync_interface_descriptions, batch.operation
      assert_equal({ total: 1, succeeded: 1, failed: 0, partial: 0, missing_credentials: 0, callback_errors: 0 }, batch.summary)
      assert_equal 1, fixtures.size
      assert fixtures.first.transport.closed?
      assert_equal 1, fixtures.first.transport.closes
      assert_same batch.outcomes.first, notified.fetch(0)
      assert_match(/\ATo_peer_/, fixtures.first.description)
    end
  end

  def test_sync_readback_failure_does_not_save_or_reconnect
    each_fleet(fault: :mismatch, continuous: true) do |fleet, fixtures|
      batch = fleet.sync_interface_descriptions(hosts: [HOST])
      assert_equal 1, batch.summary.fetch(:failed)
      assert batch.outcomes.first.partial?
      assert_equal :description_unconfirmed, batch.outcomes.first.error.code
      assert_equal 1, fixtures.size
      refute(fixtures.first.observed.any? { |command, _| command == fixtures.first.sample.fetch(:save) })
      assert fixtures.first.transport.closed?
    end
  end

  # 两台真实门面使用独立合成传输；第一台读回失败不影响第二台保存与汇总。
  def test_sync_isolates_device_failure_and_reports_the_complete_requested_inventory
    fixtures = []
    hosts = [HOST, "192.0.2.2"]
    rows = hosts.map { |host| inventory_row(:cisco_ios).merge("ip" => host) }
    fleet = Netdisco::Fleet.new(settings: Netdisco::Settings.new(env: {}), inventory: Struct.new(:devices).new(rows),
                               credentials: ->(_) { { username: "operator" } },
                               connector_factory: lambda { |device, _options|
                                 fixture = TopologyFixture.new(:cisco_ios, host: device.host)
                                 fixture.mismatch = device.host == HOST
                                 fixtures << fixture
                                 fixture.device
                               })
    batch = fleet.sync_interface_descriptions(hosts: hosts)
    assert_equal(hosts, batch.outcomes.map { |outcome| outcome.device.host })
    assert_equal({ total: 2, succeeded: 1, failed: 1, partial: 1, missing_credentials: 0, callback_errors: 0 }, batch.summary)
    assert_equal :incomplete, batch.status
    assert(fixtures.all? { |fixture| fixture.transport.closed? })
    healthy = fixtures.find { |fixture| fixture.device.host == hosts.last }
    assert_equal(1, healthy.observed.count { |command, _| command == healthy.sample.fetch(:save) })
  ensure
    fixtures&.each(&:close)
  end

  private

  # 规划与应用各自拥有新连接；设备状态单独保留，符合生产会话关闭后的生命周期。
  def each_fleet(fault: nil, continuous: false)
    TopologyFixture::SAMPLES.each_key do |vendor|
      fixtures = []
      inventory = Struct.new(:devices).new([inventory_row(vendor)])
      fleet = Netdisco::Fleet.new(settings: Netdisco::Settings.new(env: {}), inventory: inventory,
                                 credentials: ->(_) { { username: "operator", password: "private-password" } },
                                 connector_factory: lambda { |_device, _options|
                                   fixture = TopologyFixture.new(vendor)
                                   apply_fault(fixture, fault) if continuous || !fixtures.empty?
                                   fixtures << fixture
                                   fixture.device
                                 })
      begin
        yield fleet, fixtures
      ensure
        fixtures.each(&:close)
      end
    end
  end

  def apply_fault(fixture, fault)
    case fault
    when :mismatch then fixture.mismatch = true
    when :save_unconfirmed then fixture.save_output = ""
    when :stale then fixture.description = "changed before apply"
    end
  end

  def inventory_row(vendor)
    case vendor
    when :cisco_ios then { "ip" => HOST, "vendor" => "Cisco", "os" => "ios" }
    when :cisco_nxos then { "ip" => HOST, "vendor" => "Cisco", "os" => "nxos" }
    when :h3c then { "ip" => HOST, "vendor" => "H3C" }
    when :hillstone then { "ip" => HOST, "vendor" => "Hillstone" }
    end
  end
end
