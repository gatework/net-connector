# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class TopologyConcurrencyTest < Minitest::Test
  def setup
    @description = "original"
    @transport = ConnectorFake.new("switch#")
    @transport.on_write = lambda do |bytes, _timeout|
      command = bytes.strip
      body = case command
             when "show cdp neighbors detail"
               "Device ID: peer\r\nInterface: GigabitEthernet1/0/1, Port ID (outgoing port): GigabitEthernet1/0/2\r\n"
             when "show running-config"
               "interface GigabitEthernet1/0/1\r\n description #{@description}\r\n!\r\nend\r\n"
             else
               @description = command.delete_prefix("description ") if command.start_with?("description ")
               ""
             end
      @transport.events << "#{command}\r\n#{body}switch#"
    end
    @device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit", transport: @transport)
  end

  def teardown
    @resume << true if @resume
    if @applying
      @applying.join(3)
      raise "topology test thread did not finish" if @applying.alive?
    end
    @device.close
  end

  def test_revalidation_write_and_readback_share_one_operation_lock
    plan = @device.plan_interface_descriptions { "planned" }
    checked = Queue.new
    @resume = Queue.new
    resume = @resume
    collect = @device.method(:running_config)
    pause_once = true
    @device.define_singleton_method(:running_config) do
      result = collect.call
      if pause_once
        pause_once = false
        checked << true
        Timeout.timeout(3) { resume.pop }
      end
      result
    end
    @applying = Thread.new { @device.apply_interface_descriptions(plan, confirmed: true) }
    @applying.report_on_exception = false
    Timeout.timeout(3) { checked.pop }
    concurrent = @device.execute_script(["configure terminal", "interface GigabitEthernet1/0/1", "description concurrent", "end"])
    @resume << true
    Timeout.timeout(3) { @applying.join }
    result = @applying.value
    assert_instance_of Net::Connector::SessionBusy, concurrent.error
    refute_includes @transport.writes, "description concurrent\n"
    assert result.success?, result.error.inspect
    assert_equal "planned", @description
    assert @device.execute("show version").success?, "operation must release its lease"
  end

  def test_facade_forwards_description_format_options
    plan = @device.plan_interface_descriptions(abbreviate: false, lowercase: true)
    assert_equal "To peer gigabitethernet1/0/2", plan.changes.first.new_description
    assert_equal "GigabitEthernet1/0/1", plan.changes.first.interface
    assert_equal "GigabitEthernet1/0/2", plan.changes.first.neighbor.neighbor_interface
  end

  def test_stale_plan_releases_operation_lock_without_applying_changes
    plan = @device.plan_interface_descriptions { "planned" }
    @description = "changed before apply"
    error = assert_raises(Net::Connector::DeviceError) { @device.apply_interface_descriptions(plan, confirmed: true) }
    assert_equal :stale_plan, error.code
    refute_includes @transport.writes, "description planned\n"
    assert @device.execute("show version").success?
  end

  def test_callbacks_cannot_reenter_an_operation_owned_script
    nested = nil
    closed = nil
    @device.with_operation(:test) do
      result = @device.execute("show version") do
        nested = @device.execute("interleaved")
        closed = assert_raises(Net::Connector::SessionBusy) { @device.close }
      end
      assert result.success?, result.error.inspect
      assert @device.execute("show next").success?
    end
    assert_instance_of Net::Connector::SessionBusy, nested.error
    assert_equal :session_busy, closed.code
    refute_includes @transport.writes, "interleaved\n"
    assert @device.execute("show final").success?
  end

  def test_other_fiber_cannot_borrow_an_operation_lease
    @device.with_operation(:test) do
      result = Fiber.new { @device.execute("interleaved") }.resume
      assert_instance_of Net::Connector::SessionBusy, result.error
      assert @device.execute("show version").success?
    end
    refute_includes @transport.writes, "interleaved\n"
  end

  def test_readback_failure_preserves_completed_changes_and_releases_the_lease
    plan = @device.plan_interface_descriptions { "planned" }
    collect = @device.method(:running_config)
    calls = 0
    @device.define_singleton_method(:running_config) do
      calls += 1
      raise Net::Connector::ParsingError.new("readback incomplete", code: :unrecognized_output) if calls == 2

      collect.call
    end
    result = @device.apply_interface_descriptions(plan, confirmed: true)
    assert result.failure?
    assert_equal :unrecognized_output, result.error.code
    assert_includes result.steps.map { |step| step.command.text }, "description planned"
    assert_equal "planned", @description
    assert @device.execute("show version").success?
  end
end
