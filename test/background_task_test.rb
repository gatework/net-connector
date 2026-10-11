# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require_relative "../lib/net/connector/background_task"

class BackgroundTaskTest < Minitest::Test
  BackgroundTask = Net::Connector::BackgroundTask

  def test_validates_before_creating_threads
    assert_raises(ArgumentError) { BackgroundTask.run(task: nil, stop: -> {}) {} }
    assert_raises(ArgumentError) { BackgroundTask.run(task: -> {}, stop: nil) {} }
    assert_raises(ArgumentError) { BackgroundTask.run(task: -> {}, stop: -> {}) }
  end

  def test_success_preserves_value_and_joins_owned_thread
    started, stopped = Queue.new, Queue.new
    worker = nil
    result = BackgroundTask.run(task: -> { worker = Thread.current; started << true; stopped.pop }, stop: -> { stopped << true }) do
      started.pop
      :foreground_result
    end
    assert_equal :foreground_result, result
    refute worker.alive?
  end

  def test_primary_interrupt_wins_over_background_and_stop_failures
    started = Queue.new
    primary = Interrupt.new("foreground cancellation")
    secondary = RuntimeError.new("background failure")
    worker = nil
    operation = lambda do
      BackgroundTask.run(task: -> { worker = Thread.current; started << true; raise secondary },
                         stop: -> { raise IOError, "stop failure" }) do
        started.pop
        raise primary
      end
    end
    assert_same primary, assert_raises(Interrupt, &operation)
    refute worker.alive?
  end

  def test_background_failure_is_observable_after_normal_foreground
    failure = RuntimeError.new("background failure")
    operation = -> { BackgroundTask.run(task: -> { raise failure }, stop: -> {}) { :completed } }
    assert_same failure, assert_raises(RuntimeError, &operation)
  end

  def test_observer_restores_interrupt_delivery_inside_inherited_creation_mask
    started, blocked, released = Queue.new, Queue.new, Queue.new
    failure = Interrupt.new("observer cancellation")
    task = lambda do
      started << Thread.current
      blocked.pop
    ensure
      released << true
    end
    operation = lambda do
      BackgroundTask.run(task: task, stop: -> { blocked << true }) do
        started.pop.raise(failure)
        Timeout.timeout(2) { released.pop }
        :completed
      end
    end
    assert_same failure, assert_raises(Interrupt, &operation)
  end

  def test_global_abort_on_exception_does_not_interrupt_unrelated_owner
    original = Thread.abort_on_exception
    Thread.abort_on_exception = true
    result = Queue.new
    worker = Thread.new do
      failure = RuntimeError.new("observer failure")
      begin
        BackgroundTask.run(task: -> { raise failure }, stop: -> {}) { :completed }
      rescue RuntimeError => observed
        result << observed.equal?(failure)
      end
    end
    worker.join
    assert result.pop
  ensure
    Thread.abort_on_exception = original
  end

  def test_asynchronous_cancellation_during_creation_still_registers_and_joins_thread
    original = Thread.method(:new)
    caller = Thread.current
    cancellation = Interrupt.new("cancel during registration")
    stopped = Queue.new
    worker = nil
    create = lambda do |&block|
      worker = original.call(&block)
      caller.raise(cancellation)
      worker
    end
    Thread.stub(:new, create) do
      observed = assert_raises(Interrupt) do
        BackgroundTask.run(task: -> { stopped.pop }, stop: -> { stopped << true }) { flunk "foreground must not begin" }
      end
      assert_same cancellation, observed
    end
    refute worker.alive?
  end

  def test_stop_failure_still_terminates_and_joins_observer
    started = Queue.new
    blocked = Queue.new
    worker = nil
    failure = IOError.new("stop failure")
    operation = lambda do
      BackgroundTask.run(task: -> { worker = Thread.current; started << true; blocked.pop }, stop: -> { raise failure }) do
        started.pop
        :completed
      end
    end
    assert_same failure, assert_raises(IOError, &operation)
    refute worker.alive?
  end

  def test_second_asynchronous_interrupt_does_not_skip_join_or_replace_primary
    started, stopped = Queue.new, Queue.new
    worker = nil
    primary = Interrupt.new("first cancellation")
    secondary = Interrupt.new("second cancellation")
    stop = -> { Thread.current.raise(secondary); stopped << true }
    operation = lambda do
      BackgroundTask.run(task: -> { worker = Thread.current; started << true; stopped.pop }, stop: stop) do
        started.pop
        raise primary
      end
    end
    assert_same primary, assert_raises(Interrupt, &operation)
    refute worker.alive?
  end

  def test_failed_thread_creation_preserves_failure_and_does_not_stop_an_unowned_thread
    failure = ThreadError.new("observer creation failed")
    Thread.stub(:new, ->(*) { raise failure }) do
      operation = -> { BackgroundTask.run(task: -> {}, stop: -> { flunk "no observer to stop" }) { flunk "no foreground" } }
      assert_same failure, assert_raises(ThreadError, &operation)
    end
  end

  def test_join_failure_is_observed_after_normal_result_and_preserves_primary
    [nil, Interrupt.new("foreground cancellation")].each do |primary|
      started = Queue.new
      join_failure = IOError.new("join failure")
      worker = nil
      task = lambda do
        worker = Thread.current
        actual_join = worker.method(:join)
        worker.define_singleton_method(:join) do
          actual_join.call
          Kernel.raise join_failure
        end
        started << true
      end
      operation = lambda do
        BackgroundTask.run(task: task, stop: -> {}) do
          started.pop
          raise primary if primary

          :completed
        end
      end
      failure = primary || join_failure
      assert_same failure, assert_raises(failure.class, &operation)
      refute worker.alive?
    end
  end

  def test_break_and_nonlocal_return_preserve_their_values_after_releasing_observer
    [:break, :return].each do |exit_kind|
      worker = nil
      stopped = Queue.new
      task = -> { worker = Thread.current; stopped.pop }
      stop = -> { stopped << true }
      result = if exit_kind == :break
                 BackgroundTask.run(task: task, stop: stop) { break :escaped }
               else
                 return_from_background(task: task, stop: stop)
               end
      assert_equal :escaped, result
      refute worker.alive?
    end
  end

  def test_break_and_nonlocal_return_cannot_swallow_cleanup_failure_or_cancellation
    [:break, :return].each do |exit_kind|
      [IOError.new("stop failure"), Interrupt.new("cleanup cancellation")].each do |failure|
        worker = nil
        task = -> { worker = Thread.current }
        stop = -> { raise failure }
        operation = lambda do
          if exit_kind == :break
            BackgroundTask.run(task: task, stop: stop) { break :escaped }
          else
            return_from_background(task: task, stop: stop)
          end
        end
        assert_same failure, assert_raises(failure.class, &operation)
        refute worker&.alive?
      end
    end
  end

  def test_break_cannot_swallow_observer_cancellation
    failure = Interrupt.new("observer cancellation")
    operation = -> { BackgroundTask.run(task: -> { raise failure }, stop: -> {}) { break :escaped } }
    assert_same failure, assert_raises(Interrupt, &operation)
  end

  private

  def return_from_background(task:, stop:)
    BackgroundTask.run(task: task, stop: stop) { return :escaped }
    flunk "nonlocal return must leave its caller"
  end
end
