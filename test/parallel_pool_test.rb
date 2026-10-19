# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "timeout"
require_relative "../lib/net/connector/parallel/pool"

class ParallelPoolTest < Minitest::Test
  Pool = Net::Connector::Parallel::Pool

  def test_environment_default_and_explicit_override
    assert_equal 4, Pool.environment_parallel(env: {})
    assert_equal 7, Pool.environment_parallel(env: { "NC_PARALLEL" => "7" })
    assert_equal 50, Pool.environment_parallel(env: { "NC_PARALLEL" => "50" })
    [nil, false, 3, "", "0", "-1", "1.5", "501", " 2 "].each do |value|
      assert_raises(ArgumentError) { Pool.environment_parallel(env: { "NC_PARALLEL" => value }) }
    end
    assert_equal [6], Pool.new(parallel: 1).map([3]) { |value| value * 2 }
  end

  def test_bounds_parallel_work_and_returns_values_in_input_order
    started = Queue.new
    release = Queue.new
    mutex = Mutex.new
    active = peak = 0
    runner = Thread.new do
      Pool.new(parallel: 2).map([0, 1, 2, 3]) do |index|
        mutex.synchronize { active += 1; peak = [peak, active].max }
        started << index
        release.pop
        mutex.synchronize { active -= 1 }
        index * 2
      end
    end
    2.times { started.pop }
    assert_equal 2, peak
    2.times { release << true }
    2.times { started.pop }
    2.times { release << true }
    assert_equal [0, 2, 4, 6], runner.value
    assert_equal 2, peak
  ensure
    runner&.kill
    runner&.join
  end

  def test_empty_and_invalid_inputs_do_not_create_threads
    Thread.stub(:new, ->(*) { flunk "must not create threads" }) do
      assert_empty Pool.new(parallel: 1).map([]) { flunk "no tasks" }
      assert_raises(ArgumentError) { Pool.new(parallel: 1).map(nil) {} }
      assert_raises(ArgumentError) { Pool.new(parallel: 1).map([1]) }
    end
  end

  def test_partial_thread_creation_failure_never_starts_business_work
    original = ThreadError.new("worker creation failed")
    thread_new = Thread.method(:new)
    created = []
    calls = Queue.new
    blocker = Queue.new
    spawn = lambda do |&operation|
      raise original unless created.empty?

      thread = thread_new.call(&operation)
      created << thread
      # 新实现停在启动闸门；旧实现停在设备块，两者都能确定达到休眠而不挂住测试。
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until thread.status == "sleep"
        raise "worker did not reach startup boundary" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        Thread.pass
      end
      thread
    end
    Thread.stub(:new, spawn) do
      raised = assert_raises(ThreadError) do
        Pool.new(parallel: 2).map([1, 2]) do |item|
          calls << item
          blocker.pop
        end
      end
      assert_same original, raised
    end
    assert_empty created.select(&:alive?)
    assert_empty calls, "线程创建尚未全部成功时，不应调用任何业务块"
  ensure
    created&.each(&:kill)
    created&.each(&:join)
  end

  def test_task_array_is_snapshotted_before_threads_are_created
    items = [1, 2, 3]
    thread_new = Thread.method(:new)
    spawn = lambda do |&operation|
      items.replace([99])
      thread_new.call(&operation)
    end
    Thread.stub(:new, spawn) do
      assert_equal [2, 4, 6], Pool.new(parallel: 2).map(items) { |item| item * 2 }
    end
    assert_equal [99], items
  end

  def test_cleanup_join_failure_does_not_replace_original_task_error
    original = Interrupt.new("operation interrupted")
    thread_new = Thread.method(:new)
    started = Queue.new
    blocker = Queue.new
    created = []
    joined = []
    blocked_thread = nil
    spawn = lambda do |&operation|
      thread = thread_new.call(&operation)
      created << thread
      thread
    end
    Thread.stub(:new, spawn) do
      raised = assert_raises(Interrupt) do
        Pool.new(parallel: 2).map([:blocked, :failed]) do |item|
          if item == :failed
            started.pop
            raise original
          end
          # 任务领取顺序不等于线程创建顺序；故障只注入实际被取消的阻塞线程。
          blocked_thread = Thread.current
          actual_join = blocked_thread.method(:join)
          blocked_thread.define_singleton_method(:join) do |*arguments|
            result = actual_join.call(*arguments)
            joined << self
            # 阻塞任务只能在取消清理时结束；真实回收后注入一次次级等待故障。
            Kernel.raise IOError, "secondary join failed" if joined.size == 1

            result
          end
          started << true
          blocker.pop
        end
      end
      assert_same original, raised
    end
    assert_equal [blocked_thread], joined
    assert_equal 2, created.size
    assert_empty created.select(&:alive?)
  ensure
    created&.each(&:kill)
    created&.each(&:join)
  end

  def test_deferred_cleanup_cancellation_cannot_create_a_circular_error_cause
    original = IOError.new("task failed")
    thread_new = Thread.method(:new)
    created = []
    spawn = lambda do |&operation|
      thread = thread_new.call(&operation)
      created << thread
      actual_kill = thread.method(:kill)
      thread.define_singleton_method(:kill) do
        result = actual_kill.call
        # 在原故障的 rescue 内排队二次取消，Ruby 会把原故障设为其隐式 cause。
        Thread.current.raise(Interrupt.new("cancel cleanup"))
        result
      end
      thread
    end

    Thread.stub(:new, spawn) do
      operation = ->(_) { raise original }
      raised = assert_raises(IOError) { Pool.new(parallel: 1).map([1], &operation) }
      assert_same original, raised
      assert_nil raised.cause
    end
    assert_empty created.select(&:alive?)
  ensure
    created&.each { |thread| Thread.instance_method(:kill).bind_call(thread) }
    created&.each(&:join)
  end

  def test_async_cancellation_between_creation_and_registration_reclaims_worker
    original = Interrupt.new("cancel while registering worker")
    thread_new = Thread.method(:new)
    observed = Queue.new
    release = Queue.new
    calls = Queue.new
    created = []
    spawn = lambda do |&operation|
      thread = thread_new.call(&operation)
      created << thread
      observed << thread
      # 固定在线程已创建、Thread.new 尚未返回的位置，从外部取消批次调用线程。
      release.pop
      thread
    end
    runner = thread_new.call do
      Thread.stub(:new, spawn) do
        Pool.new(parallel: 1).map([1]) { |item| calls << item }
      end
    rescue Interrupt => error
      error
    end
    observed.pop
    runner.raise(original)
    release << true
    assert runner.join(2), "登记临界区退出后，异步中断应及时交付调用线程"
    assert_same original, runner.value
    assert_equal 1, created.size
    assert_empty created.select(&:alive?)
    assert_empty calls
  ensure
    release&.push(true)
    runner&.kill
    runner&.join
    created&.each(&:kill)
    created&.each(&:join)
  end

  def test_later_worker_failure_stops_and_joins_an_earlier_blocked_task
    [RuntimeError.new("task failed"), Interrupt.new("task interrupted"), SystemExit.new(7)].each do |original|
      started = Queue.new
      blocker = Queue.new
      cleaned = Queue.new
      runner = Thread.new do
        Pool.new(parallel: 2).map([:blocked, :failed]) do |item|
          if item == :failed
            started.pop
            raise original
          end
          begin
            started << Thread.current
            blocker.pop
          ensure
            cleaned << Thread.current
          end
        end
      rescue Exception => error # rubocop:disable Lint/RescueException -- 测试三种取消类别均同步交付调用线程，避免异常逃出测试线程。
        error
      end
      assert runner.join(2), "后启动任务失败时，不应等待前一台设备自行结束"
      assert_same original, runner.value
      thread = Timeout.timeout(2) { cleaned.pop }
      refute thread.alive?, "调用方返回前必须回收已停止任务"
    ensure
      runner&.kill
      runner&.join
    end
  end

  def test_second_asynchronous_cancellation_during_cleanup_joins_all_owned_workers
    original = RuntimeError.new("task failure")
    secondary = Interrupt.new("second cancellation")
    thread_new = Thread.method(:new)
    started, kill_observed, release = Queue.new, Queue.new, Queue.new
    blocker = Queue.new
    created = []
    intercepted = false
    spawn = lambda do |&operation|
      thread = thread_new.call(&operation)
      created << thread
      actual_kill = thread.method(:kill)
      thread.define_singleton_method(:kill) do
        result = actual_kill.call
        unless intercepted
          intercepted = true
          # 已调用真实 kill，尚未取消其他设备时，从外部交付第二次异步取消。
          kill_observed << true
          release.pop
        end
        result
      end
      thread
    end
    runner = thread_new.call do
      Thread.stub(:new, spawn) do
        Pool.new(parallel: 3).map([:blocked, :blocked, :failed]) do |item|
          if item == :failed
            2.times { started.pop }
            raise original
          end
          started << true
          blocker.pop
        end
      end
    rescue Exception => error # rubocop:disable Lint/RescueException -- 测试由批次所有者同步观察原故障与二次取消的竞争。
      error
    end
    Timeout.timeout(2) { kill_observed.pop }
    runner.raise(secondary)
    release << true
    assert runner.join(2), "二次取消不得跳过剩余线程收尾"
    assert_same original, runner.value
    assert_equal 3, created.size
    assert_empty created.select(&:alive?)
  ensure
    release&.push(true)
    created&.each { |thread| Thread.instance_method(:kill).bind_call(thread) }
    created&.each(&:join)
    runner&.kill
    runner&.join
  end

  def test_cancelled_task_cleanup_exception_does_not_escape_global_abort_policy
    # kill 也会执行设备 ensure；其异常不得覆盖原中断或异步逃逸到宿主主线程。
    source = <<~'CODE'
      require "net/connector/parallel/pool"
      Thread.abort_on_exception = true
      failure = Interrupt.new("original interruption")
      ready = Queue.new
      cleaned = Queue.new
      blocker = Queue.new
      runner = Thread.new do
        begin
          Net::Connector::Parallel::Pool.new(parallel: 2).map([:blocked, :failed]) do |item|
            if item == :failed
              ready.pop
              raise failure
            end
            begin
              ready << true
              blocker.pop
            ensure
              cleaned << Thread.current
              raise SystemExit.new(7)
            end
          end
        rescue Interrupt => error
          raise "wrong exception" unless error.equal?(failure)
          :observed
        end
      end
      raise "caller remained blocked" unless runner.join(2)
      raise "not observed" unless runner.value == :observed
      raise "cleanup did not finish" unless cleaned.size == 1 && !cleaned.pop.alive?
      sleep 0.02
      puts "cleanup completed without replacing original interruption"
    CODE
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", source)
    assert status.success?, error
    assert_equal "cleanup completed without replacing original interruption\n", output
  end

  def test_failure_returns_to_calling_thread_even_with_global_abort_enabled
    # 在子进程启用宿主全局策略，避免旧实现异步中断主线程导致测试进程提前退出。
    source = <<~'CODE'
      require "net/connector/parallel/pool"
      Thread.abort_on_exception = true
      failure = Interrupt.new("owned interruption")
      runner = Thread.new do
        begin
          Net::Connector::Parallel::Pool.new(parallel: 1).map([1]) { raise failure }
        rescue Interrupt => error
          raise "wrong exception" unless error.equal?(failure)
          :observed
        end
      end
      raise "not observed" unless runner.value == :observed
      sleep 0.02
      puts "caller observed original interruption"
    CODE
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", source)
    assert status.success?, error
    assert_equal "caller observed original interruption\n", output
  end
end
