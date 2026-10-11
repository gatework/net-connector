# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/device_session"

class DeviceSessionTest < Minitest::Test
  Session = Net::Connector::DeviceSession

  def test_success_and_close_failure_preserve_value
    failure = IOError.new("close failure")
    connector = Object.new
    connector.define_singleton_method(:close) { raise failure }
    value, error = Session.call(factory: -> { connector }) { :completed }
    assert_equal :completed, value
    assert_same failure, error
  end

  def test_first_interrupt_survives_secondary_cleanup_interrupt
    failure = Interrupt.new("operation interrupted")
    connector = Object.new
    closes = 0
    connector.define_singleton_method(:close) { closes += 1; raise Interrupt, "close interrupted" }
    error = assert_raises(Interrupt) { Session.call(factory: -> { connector }) { raise failure } }
    assert_same failure, error
    assert_equal 1, closes
  end

  def test_first_standard_failure_survives_secondary_cleanup_interrupt
    failure = IOError.new("operation failed")
    connector = Object.new
    connector.define_singleton_method(:close) { raise Interrupt, "close interrupted" }
    value, error = Session.call(factory: -> { connector }) { raise failure }
    assert_nil value
    assert_same failure, error
  end

  def test_interrupt_from_close_propagates_when_operation_succeeded
    failure = Interrupt.new("close interrupted")
    connector = Object.new
    connector.define_singleton_method(:close) { raise failure }
    assert_same failure, assert_raises(Interrupt) { Session.call(factory: -> { connector }) { :completed } }
  end

  def test_failed_factory_is_not_closed_and_missing_block_does_not_construct
    failure = IOError.new("constructor failed")
    assert_equal [nil, failure], Session.call(factory: -> { raise failure }) { flunk "must not run" }
    assert_raises(ArgumentError) { Session.call(factory: -> { flunk "must not construct" }) }
    assert_raises(ArgumentError) { Session.call(factory: nil) {} }
  end

  def test_cancel_at_factory_return_handoff_closes_registered_connector
    failure = Interrupt.new("cancel at handoff")
    closed = false
    connector = Object.new
    connector.define_singleton_method(:close) { closed = true }
    factory = lambda do
      # Thread#raise 模拟已经到达的异步取消；工厂没有阻塞，先完成返回交接。
      Thread.current.raise(failure)
      connector
    end
    observed = assert_raises(Interrupt) { Session.call(factory: factory) { flunk "operation must not run" } }
    assert_same failure, observed
    assert closed
  end

  def test_blocking_factory_remains_interruptible_and_owns_partial_resources
    entered = Queue.new
    cleaned = Queue.new
    blocker = Queue.new
    thread = Thread.new do
      Session.call(factory: lambda {
        entered << true
        begin
          blocker.pop
        ensure
          cleaned << true
        end
      }) { flunk "operation must not run" }
    rescue Interrupt => error
      error
    end
    entered.pop
    failure = Interrupt.new("blocked factory cancelled")
    thread.raise(failure)
    assert_same failure, thread.value
    assert cleaned.pop
  ensure
    thread&.kill
    thread&.join
  end

  def test_nonlocal_exit_delivers_close_failure
    [IOError.new("close failed"), Interrupt.new("close cancelled")].each do |failure|
      connector = Object.new
      connector.define_singleton_method(:close) { raise failure }
      observed = assert_raises(failure.class) { Session.call(factory: -> { connector }) { break :escaped } }
      assert_same failure, observed
      observed = assert_raises(failure.class) { return_from_session(connector) }
      assert_same failure, observed
    end
  end

  private

  def return_from_session(connector)
    Session.call(factory: -> { connector }) { return :escaped }
  end
end
