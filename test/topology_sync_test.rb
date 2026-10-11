# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require_relative "../lib/net/connector"
require_relative "support/topology_fixture"

class TopologySyncTest < Minitest::Test
  def test_default_sync_discovers_changes_reads_back_and_saves_in_one_session
    each_fixture do |fixture|
      result = fixture.device.sync_interface_descriptions
      assert result.success?, result.error.inspect
      assert_match(/\ATo_peer_/, fixture.description)
      changed = fixture.observed.index { |command, _| command.start_with?("description ") }
      verified = fixture.observed.rindex { |command, _| command == fixture.sample.fetch(:collect) }
      saved = fixture.observed.index { |command, _| command == fixture.sample.fetch(:save) }
      assert_operator changed, :<, verified
      assert_operator verified, :<, saved
      assert_equal(1, fixture.observed.count { |command, _| command == fixture.sample.fetch(:save) })
      assert_includes result.steps.map { |step| step.command.text }, "description #{fixture.description}"
    end
  end

  # 名称规则必须贯通邻居解析、配置关联与实际下发，不能只验证展示函数。
  def test_vendor_high_speed_and_aggregate_interfaces_sync_without_rewriting_local_identity
    cases = [
      [:h3c, "BAGG25", "Bridge-Aggregation25", "Port-channel25", "Po25"],
      [:h3c, "RAGG25", "Route-Aggregation25", "aggregate25", "Agg25"],
      [:h3c, "WGE1/0/1:2", "Twenty-FiveGigE1/0/1:2", "TwentyFiveGigE1/0/2", "Twe1/0/2"],
      [:h3c, "FGE1/0/1", "FortyGigE1/0/1", "FortyGigabitEthernet1/0/2", "Fo1/0/2"],
      [:h3c, "HGE1/0/1", "HundredGigE1/0/1", "HundredGigE1/0/2", "Hu1/0/2"],
      [:cisco_ios, "Port-channel25", "Port-channel25", "Bridge-Aggregation25", "BAGG25"],
      [:hillstone, "aggregate25", "aggregate25", "Route-Aggregation25", "RAGG25"],
      [:hillstone, "xethernet0/1", "xethernet0/1", "XGE1/0/2", "Te1/0/2"]
    ]
    cases.each do |vendor, local, configured, remote, expected|
      neighbor = case vendor
                 when :h3c then "Local Interface Chassis ID Port ID System Name\n#{local} 000f-e25d-ee91 #{remote} peer\n"
                 when :cisco_ios then "Device ID: peer\nInterface: #{local}, Port ID (outgoing port): #{remote}\n"
                 when :hillstone then "System Name Local Interface Chassis ID Port ID\npeer #{local} 000f-e25d-ee91 #{remote}\nTotal lldp neighbor number: 1.\n"
                 end
      fixture = TopologyFixture.new(vendor, interface: configured, neighbor: neighbor)
      result = fixture.device.sync_interface_descriptions
      assert result.success?, "#{local}: #{result.error.inspect}"
      assert_equal "To_peer_#{expected}", fixture.description
      assert_equal local, fixture.device.neighbors.first.local_interface
      assert_equal remote, fixture.device.neighbors.first.neighbor_interface
      assert_includes fixture.observed.map(&:first), "interface #{Net::Connector::Topology::InterfaceName.configuration(local)}"
      assert_equal(1, fixture.observed.count { |command, _| command == fixture.sample.fetch(:save) })
    ensure
      fixture&.close
    end
  end

  def test_unchanged_descriptions_do_not_enter_configuration_or_save_again
    each_fixture do |fixture|
      fixture.device.sync_interface_descriptions.value!
      fixture.observed.clear
      result = fixture.device.sync_interface_descriptions
      assert result.success?
      assert_empty result.steps
      refute(fixture.observed.any? { |command, _| [fixture.sample.fetch(:enter), fixture.sample.fetch(:save)].include?(command) })
    end
  end

  def test_custom_formatter_and_format_options_remain_backend_choices
    each_fixture do |fixture|
      result = fixture.device.sync_interface_descriptions(abbreviate: false, lowercase: true)
      assert result.success?
      assert_equal "To_peer_#{fixture.device.neighbors.first.neighbor_interface.downcase}", fixture.description
      result = fixture.device.sync_interface_descriptions { "custom uplink" }
      assert result.success?
      assert_equal "custom uplink", fixture.description
    end
  end

  def test_readback_failure_keeps_completed_changes_without_saving
    each_fixture do |fixture|
      fixture.mismatch = true
      result = fixture.device.sync_interface_descriptions
      assert result.failure?
      assert_equal :description_unconfirmed, result.error.code
      assert(result.steps.any? { |step| step.command.text.start_with?("description ") })
      refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:save) })
      assert fixture.device.execute_command("show version").success?
    end
  end

  def test_unconfirmed_persistence_is_not_replayed
    each_fixture do |fixture|
      fixture.save_output = ""
      result = fixture.device.sync_interface_descriptions
      assert result.failure?
      assert_equal :persistence_unconfirmed, result.error.code
      assert_equal(1, fixture.observed.count { |command, _| command == fixture.sample.fetch(:save) })
    end
  end

  def test_external_neighbor_changes_still_block_writes
    each_fixture do |fixture|
      command = fixture.device.profile.topology_strategy.new(fixture.device).neighbor_command
      reads = 0
      fixture.on_command = lambda do |sent|
        reads += 1 if sent == command
        fixture.description = "changed externally" if reads == 2
      end
      error = assert_raises(Net::Connector::DeviceError) { fixture.device.sync_interface_descriptions }
      assert_equal :stale_plan, error.code
      refute(fixture.observed.any? { |sent, _| sent == fixture.sample.fetch(:enter) })
      assert fixture.device.execute_command("show version").success?
    end
  end

  def test_invalid_format_options_fail_without_opening_the_transport
    each_fixture do |fixture|
      [{ abbreviate: nil }, { lowercase: "true" }].each do |options|
        assert_raises(ArgumentError) { fixture.device.sync_interface_descriptions(**options) }
      end
      assert_empty fixture.observed
      assert_equal 0, fixture.transport.opens
    end
  end

  def test_unsafe_description_is_rejected_before_any_write
    each_fixture do |fixture|
      assert_raises(ArgumentError) { fixture.device.sync_interface_descriptions { "uplink\nreload" } }
      refute(fixture.observed.any? { |sent, _| sent == fixture.sample.fetch(:enter) })
      assert fixture.device.execute_command("show version").success?
    end
  end

  # 从首次发现开始持有租约，另一线程不能在格式化与写入之间插入设备操作。
  def test_discovery_and_application_share_one_lease
    fixture = TopologyFixture.new(:cisco_ios)
    discovered = Queue.new
    resume = Queue.new
    worker = Thread.new do
      fixture.device.sync_interface_descriptions do |_neighbor|
        discovered << true
        Timeout.timeout(3) { resume.pop }
        "planned"
      end
    end
    worker.report_on_exception = false
    Timeout.timeout(3) { discovered.pop }
    concurrent = fixture.device.execute_command("interleaved")
    assert_instance_of Net::Connector::SessionBusy, concurrent.error
    refute_includes fixture.transport.writes, "interleaved\n"
    resume << true
    Timeout.timeout(3) { worker.join }
    assert worker.value.success?, worker.value.error.inspect
    assert fixture.device.execute_command("show version").success?
  ensure
    resume << true if resume
    worker&.join(3)
    fixture&.close
  end

  private

  def each_fixture
    TopologyFixture::SAMPLES.each_key do |vendor|
      fixture = TopologyFixture.new(vendor)
      yield fixture
    ensure
      fixture&.close
    end
  end
end
