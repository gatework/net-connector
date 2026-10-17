# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class SessionLockTest < Minitest::Test
  ENTRIES = %i[perform with_operation close].freeze

  def test_cancel_after_lock_acquisition_releases_every_entry
    ENTRIES.each do |entry|
      with_session do |session, lock, _transport|
        acquire = lock.method(:try_lock)
        cancellation = Interrupt.new("cancel at lock handoff")
        intercept = lambda do
          acquired = acquire.call
          Thread.current.raise(cancellation)
          acquired
        end
        lock.stub(:try_lock, intercept) do
          error = assert_raises(Interrupt) { invoke(session, entry) { flunk "cancelled body ran" } }
          assert_same cancellation, error
        end
        refute lock.locked?, entry.to_s
        assert_nil session.instance_variable_get(:@operation_owner)
        session.close
      end
    end
  end

  def test_cleanup_cancellation_releases_lock_and_preserves_a_prior_failure
    ENTRIES.each do |entry|
      [nil, Interrupt.new("first cancellation"), IOError.new("first failure")].each do |primary|
        with_session do |session, lock, transport|
          session.connect
          transport.on_close = -> { raise primary if primary } if entry == :close
          unlock = lock.method(:unlock)
          secondary = Interrupt.new("cancel during unlock")
          intercept = -> { Thread.current.raise(secondary); unlock.call }
          expected = if primary.is_a?(IOError) && entry != :with_operation
                       Net::Connector::TransportError
                     else
                       (primary || secondary).class
                     end
          lock.stub(:unlock, intercept) do
            error = assert_raises(expected) { invoke(session, entry) { raise primary if primary } }
            if expected == Net::Connector::TransportError
              assert_equal "IOError", error.underlying.type
            else
              assert_same primary || secondary, error
            end
            assert_nil error.cause
          end
          refute lock.locked?, entry.to_s
          assert_nil session.instance_variable_get(:@operation_owner)
        end
      end
    end
  end

  def test_business_wait_remains_cancellable
    ENTRIES.each do |entry|
      with_session do |session, lock, transport|
        session.connect
        entered, blocked = Queue.new, Queue.new
        operation = -> { entered << true; blocked.pop }
        transport.on_close = operation if entry == :close
        worker = Thread.new do
          invoke(session, entry, &operation)
        rescue Interrupt => error
          error
        end
        entered.pop
        cancellation = Interrupt.new("cancel business wait")
        worker.raise(cancellation)
        assert worker.join(2), "#{entry} deferred cancellation during business work"
        assert_same cancellation, worker.value
        refute lock.locked?
        assert_nil session.instance_variable_get(:@operation_owner)
      ensure
        worker&.kill&.join
      end
    end
  end

  def test_nonlocal_exits_preserve_value_and_release_operation_owner
    %i[perform with_operation].each do |entry|
      %i[break return throw].each do |exit_kind|
        with_session do |session, lock, _transport|
          value = case exit_kind
                  when :break then invoke(session, entry) { break :escaped }
                  when :return then return_from_session(session, entry)
                  when :throw then catch(:done) { invoke(session, entry) { throw :done, :escaped } }
                  end
          assert_equal :escaped, value
          refute lock.locked?
          assert_nil session.instance_variable_get(:@operation_owner)
          session.close
        end
      end
    end
  end

  def test_cancel_after_marking_performing_clears_state_and_allows_a_new_lease
    with_session do |session, lock, _transport|
      source, start_line = Net::Connector::Session.instance_method(:perform_locked).source_location
      lines = File.readlines(source)
      marked = lines.each_index.find { |index| index >= start_line - 1 && lines[index].strip == "@performing = true" }
      cancellation = Interrupt.new("cancel at performing state handoff")
      trace = TracePoint.new(:line) do |event|
        next unless event.path == source && event.lineno == marked + 2 && event.self.equal?(session)

        trace.disable
        Thread.current.raise(cancellation)
      end
      error = trace.enable { assert_raises(Interrupt) { session.perform(:probe) { flunk "cancelled body ran" } } }
      assert_same cancellation, error
      refute session.instance_variable_get(:@performing)
      refute lock.locked?
      assert_equal :done, session.with_operation(:probe) { session.perform(:probe) { :done } }
    ensure
      trace&.disable
    end
  end

  def test_cleanup_state_query_cancellation_clears_performing_and_preserves_primary_failure
    [nil, Interrupt.new("original cancellation"), IOError.new("original failure")].each do |primary|
      with_session do |session, lock, transport|
        session.connect
        cause = primary.is_a?(Interrupt) ? RuntimeError.new("original cause") : nil
        connected = session.method(:connected?)
        finishing = false
        cancellation = Interrupt.new("cancel during finish state query")
        query = lambda do
          if finishing
            finishing = false
            Thread.current.raise(cancellation)
          end
          connected.call
        end
        expected = primary.is_a?(IOError) ? Net::Connector::TransportError : Interrupt
        session.stub(:connected?, query) do
          error = assert_raises(expected) do
            session.perform(:probe) do
              finishing = true
              raise primary, cause: cause if primary

              :done
            end
          end
          if primary.is_a?(IOError)
            assert_equal "IOError", error.underlying.type
          else
            assert_same primary || cancellation, error
          end
          primary.is_a?(Interrupt) ? assert_same(cause, error.cause) : assert_nil(error.cause)
        end
        refute session.instance_variable_get(:@performing)
        refute lock.locked?
        transport.events << "router#" if transport.closed?
        assert_equal :done, session.with_operation(:probe) { session.perform(:probe) { :done } }
      end
    end
  end

  def test_cleanup_state_query_can_be_cancelled_while_blocking
    with_session do |session, lock, _transport|
      session.connect
      connected = session.method(:connected?)
      finishing = false
      entered, blocked = Queue.new, Queue.new
      worker = nil
      query = lambda do
        if finishing
          finishing = false
          entered << true
          blocked.pop
        end
        connected.call
      end
      session.stub(:connected?, query) do
        worker = Thread.new do
          session.perform(:probe) { finishing = true }
        rescue Interrupt => error
          error
        end
        entered.pop
        cancellation = Interrupt.new("cancel blocked state query")
        worker.raise(cancellation)
        assert worker.join(2), "state queries must remain interruptible"
        assert_same cancellation, worker.value
      end
      refute session.instance_variable_get(:@performing)
      refute lock.locked?
      assert_equal :done, session.with_operation(:probe) { session.perform(:probe) { :done } }
    ensure
      blocked&.push(true)
      worker&.kill&.join
    end
  end

  def test_operation_owner_can_close_without_releasing_its_lease
    with_session do |session, lock, _transport|
      session.connect
      session.with_operation(:nested_device) do
        session.close
        refute session.connected?
        assert lock.owned?
        assert_equal [Thread.current, Fiber.current], session.instance_variable_get(:@operation_owner)
      end
      refute lock.locked?
      assert_nil session.instance_variable_get(:@operation_owner)
    end
  end

  def test_other_fibers_and_threads_cannot_close_an_owned_operation
    with_session do |session, _lock, _transport|
      session.connect
      session.with_operation(:nested_device) do
        Fiber.new { assert_raises(Net::Connector::SessionBusy) { session.close } }.resume
        worker = Thread.new { assert_raises(Net::Connector::SessionBusy) { session.close } }
        assert worker.join(2)
        assert session.connected?
        session.close
      end
    end
  end

  def test_close_callbacks_cannot_reenter_an_owned_session
    with_session do |session, _lock, transport|
      session.connect
      transport.on_close = lambda do
        assert_raises(Net::Connector::SessionBusy) { session.close }
        assert_raises(Net::Connector::SessionBusy) { session.perform(:callback) { flunk "reentered close" } }
      end
      session.with_operation(:nested_device) { session.close }
      refute session.connected?
      refute session.instance_variable_get(:@closing)
    end
  end

  def test_owned_close_failure_preserves_error_and_releases_owner_state
    with_session do |session, lock, transport|
      session.connect
      transport.on_close = -> { raise IOError, "synthetic close failure" }
      error = assert_raises(Net::Connector::TransportError) do
        session.with_operation(:nested_device) { session.close }
      end
      assert_equal "IOError", error.underlying.type
      refute session.connected?
      refute session.instance_variable_get(:@closing)
      refute lock.locked?
      assert_nil session.instance_variable_get(:@operation_owner)
    end
  end

  def test_cancellation_during_owned_close_releases_close_and_owner_state
    with_session do |session, lock, transport|
      session.connect
      entered, blocked = Queue.new, Queue.new
      transport.on_close = -> { entered << true; blocked.pop }
      worker = Thread.new do
        session.with_operation(:nested_device) { session.close }
      rescue Interrupt => error
        error
      end
      entered.pop
      cancellation = Interrupt.new("cancel owned close")
      worker.raise(cancellation)
      assert worker.join(2), "owned close must remain cancellable"
      assert_same cancellation, worker.value
      refute session.connected?
      refute session.instance_variable_get(:@closing)
      refute lock.locked?
      assert_nil session.instance_variable_get(:@operation_owner)
    ensure
      worker&.kill&.join
    end
  end

  def test_owned_close_state_cleanup_preserves_the_first_cancellation
    [nil, Interrupt.new("first cancellation")].each do |primary|
      with_session do |session, lock, transport|
        session.connect
        transport.on_close = -> { raise primary if primary }
        source, start_line = Net::Connector::Session.instance_method(:close).source_location
        lines = File.readlines(source)
        reset_line = lines.each_index.find { |index| index >= start_line - 1 && lines[index].include?("Thread.handle_interrupt(Exception => :never) { @closing = false }") }
        secondary = Interrupt.new("cancel closing state cleanup")
        trace = TracePoint.new(:line) do |event|
          next unless event.path == source && event.lineno == reset_line + 1 && event.self.equal?(session)

          trace.disable
          Thread.handle_interrupt(Exception => :never) { Thread.current.raise(secondary) }
        end
        error = trace.enable do
          assert_raises(Interrupt) { session.with_operation(:nested_device) { session.close } }
        end
        assert_same primary || secondary, error
        refute session.instance_variable_get(:@closing)
        refute lock.locked?
        assert_nil session.instance_variable_get(:@operation_owner)
      ensure
        trace&.disable
      end
    end
  end

  private

  def invoke(session, entry, &)
    entry == :close ? session.close : session.public_send(entry, :probe, &)
  end

  def return_from_session(session, entry)
    invoke(session, entry) { return :escaped }
  end

  def with_session
    transport = ConnectorFake.new("router#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
    session = device.instance_variable_get(:@session)
    lock = session.instance_variable_get(:@lock)
    yield session, lock, transport
  ensure
    # 红阶段即使锁交接失败也清理测试资源，不能让一次断言污染后续入口。
    Mutex.instance_method(:unlock).bind_call(lock) if lock&.owned?
    transport.on_close = nil if transport
    device&.close
  end
end
