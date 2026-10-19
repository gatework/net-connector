# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/net/connector/netdisco"

class OperationInterruptionTest < Minitest::Test
  N = Net::Connector::Netdisco

  # 合成连接器仅在内存记录执行与关闭，不连接设备或重放配置。
  class Connection
    attr_reader :calls, :closed
    attr_accessor :action

    def initialize
      @calls = 0
    end

    def execute_script(_script)
      @calls += 1
      action&.call
      Net::Connector::Result.new
    end

    def close
      @closed = true
    end
  end

  def setup
    @rows = (1..3).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    @devices = @rows.map { |row| N::Device.from_row(row, rules: N::Rules.new) }
    @connections = @devices.to_h { |device| [device.host, Connection.new] }
    @scripts = @connections.to_h { |host, _connection| [host, ["synthetic change"]] }
    @failure = Interrupt.new("cancel synthetic batch")
    @operation = N::Operation.new(settings: N::Settings.new(env: {}), inventory: ->(_) { @devices },
                                  credentials: ->(_) { { username: "operator" } },
                                  connector_factory: ->(device, _) { @connections.fetch(device.host) })
  end

  def test_result_callback_cancellation_keeps_completed_receipt_and_unstarted_slots
    failure = @failure
    error = assert_raises(Interrupt) do
      @operation.execute_scripts(scripts: @scripts, confirmed: true, parallel: 1,
                                 on_result: ->(_) { raise failure })
    end
    assert_same failure, error
    assert_respond_to @operation, :last_batch
    batch = @operation.last_batch
    assert_equal :interrupted, batch.status
    refute batch.success?
    assert batch.interrupted
    assert_equal %i[succeeded not_started not_started], batch.outcomes.map(&:status)
    assert_same @devices.first, batch.outcomes.first.device
    assert_instance_of Net::Connector::Result, batch.outcomes.first.value
    assert_equal [1, 0, 0], @connections.values.map(&:calls)
    assert @connections.values.first.closed
    assert_equal({ total: 3, succeeded: 1, failed: 2, partial: 0, missing_credentials: 0, callback_errors: 0 }, batch.summary)
    assert_equal true, JSON.parse(JSON.generate(batch.to_h)).fetch("interrupted")
    assert batch.outcomes.frozen?
    assert_nil batch.outcomes.last.started_at
    assert_nil batch.outcomes.last.finished_at
    assert_nil batch.outcomes.last.duration_ms
  end

  def test_start_callback_cancellation_marks_current_task_without_opening_connections
    failure = @failure
    assert_raises(Interrupt) do
      @operation.execute_scripts(scripts: @scripts, confirmed: true, parallel: 1,
                                 on_start: ->(_) { raise failure })
    end
    assert_respond_to @operation, :last_batch
    assert_equal %i[interrupted not_started not_started], @operation.last_batch.outcomes.map(&:status)
    assert_instance_of Time, @operation.last_batch.outcomes.first.started_at
    assert_instance_of Time, @operation.last_batch.outcomes.first.finished_at
    assert_nil @operation.last_batch.outcomes.first.duration_ms
    assert_equal [0, 0, 0], @connections.values.map(&:calls)
    refute @operation.last_batch.success?
  end

  def test_pending_cancellation_after_perform_preserves_result_before_delivery
    failure = @failure
    @operation.define_singleton_method(:perform) do |*arguments, &block|
      value = super(*arguments, &block)
      Thread.current.raise(failure)
      value
    end
    assert_same failure, assert_raises(Interrupt) {
      @operation.execute_scripts(scripts: @scripts, confirmed: true, parallel: 1)
    }
    assert_respond_to @operation, :last_batch
    assert_equal %i[succeeded not_started not_started], @operation.last_batch.outcomes.map(&:status)
    assert @connections.values.first.closed
    refute @operation.last_batch.success?
  end

  def test_cancellation_closes_active_sibling_before_publishing_batch
    active = Queue.new
    release = Queue.new
    @connections.values[1].action = -> { active << true; release.pop }
    failure = @failure
    callback = lambda do |outcome|
      next unless outcome.device.host == @devices.first.host

      active.pop
      raise failure
    end
    assert_same failure, assert_raises(Interrupt) {
      @operation.execute_scripts(scripts: @scripts, confirmed: true, parallel: 2, on_result: callback)
    }
    assert_respond_to @operation, :last_batch
    assert_equal %i[succeeded interrupted not_started], @operation.last_batch.outcomes.map(&:status)
    assert @connections.values[0].closed
    assert @connections.values[1].closed
    assert_equal 0, @connections.values[2].calls
  ensure
    release&.push(true)
  end

  def test_successful_and_empty_runs_are_available_as_latest_batches
    batch = @operation.execute_scripts(scripts: @scripts, confirmed: true)
    assert_respond_to @operation, :last_batch
    assert_same batch, @operation.last_batch
    refute batch.interrupted
    assert batch.success?
    empty = @operation.execute_scripts(scripts: {}, confirmed: true)
    assert_same empty, @operation.last_batch
    assert_equal :no_devices, empty.status
  end

  def test_preflight_failure_clears_previous_receipt_for_every_operation_entry
    invocations = [
      -> { @operation.execute_scripts(scripts: @scripts) },
      -> { @operation.sync_descriptions(hosts: nil) },
      -> { @operation.plan_descriptions(hosts: nil) },
      -> { @operation.apply_descriptions(plans: {}, confirmed: false) }
    ]
    invocations.each do |invoke|
      @operation.execute_scripts(scripts: {}, confirmed: true)
      assert_raises(ArgumentError, &invoke)
      assert_respond_to @operation, :last_batch
      assert_nil @operation.last_batch
    end
  end

  def test_fleet_exposes_cancelled_operation_batch_and_clears_it_on_next_attempt
    fleet = N::Fleet.new(inventory: Struct.new(:devices).new(@rows), report_store: nil,
                        credentials: ->(_) { { username: "operator" } },
                        connector_factory: ->(device, _) { @connections.fetch(device.host) })
    failure = @failure
    assert_same failure, assert_raises(Interrupt) {
      fleet.execute_scripts(scripts: @scripts, confirmed: true, parallel: 1, on_result: ->(_) { raise failure })
    }
    assert_respond_to fleet, :last_operation_batch
    assert_equal %i[succeeded not_started not_started], fleet.last_operation_batch.outcomes.map(&:status)
    assert_raises(ArgumentError) { fleet.execute_scripts(scripts: @scripts) }
    assert_nil fleet.last_operation_batch
  end

  def test_prior_callback_errors_remain_available_after_later_cancellation
    failure = @failure
    callback = lambda do |outcome|
      raise IOError, "private notification" if outcome.device.host == @devices.first.host

      raise failure
    end
    assert_same failure, assert_raises(Interrupt) {
      @operation.execute_scripts(scripts: @scripts, confirmed: true, parallel: 1, on_result: callback)
    }
    batch = @operation.last_batch
    assert_equal %i[succeeded succeeded not_started], batch.outcomes.map(&:status)
    assert_equal [{ host: @devices.first.host, error_type: "IOError" }], batch.callback_errors
    refute_includes JSON.generate(batch.to_h), "private notification"
  end

  def test_cancelled_receipts_cannot_be_rewritten_as_success_or_completed_timing
    failure = @failure
    assert_raises(Interrupt) do
      @operation.execute_scripts(scripts: @scripts, confirmed: true, parallel: 1,
                                 on_start: ->(_) { raise failure })
    end
    batch = @operation.last_batch
    assert_raises(ArgumentError) { batch.with(interrupted: false) }
    assert_raises(ArgumentError) { batch.with(interrupted: nil) }
    assert_raises(ArgumentError) { batch.outcomes.first.with(status: :succeeded) }
    assert_raises(ArgumentError) { batch.outcomes.first.with(duration_ms: 0) }
    assert_raises(ArgumentError) { batch.outcomes.last.with(started_at: Time.now.utc) }
  end
end
