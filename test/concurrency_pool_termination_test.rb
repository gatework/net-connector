# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require_relative "../lib/net/connector/concurrency/pool"

class ConcurrencyPoolTerminationTest < Minitest::Test
  def test_worker_exit_reports_incomplete_work_instead_of_successful_nil_results
    visited = []
    error = assert_raises(RuntimeError) do
      Net::Connector::Concurrency::Pool.new(concurrency: 1).map([1, 2]) do |item|
        visited << item
        Thread.exit
      end
    end
    assert_equal [1], visited
    assert_match(/worker.*complet/, error.message)
  end

  def test_killed_worker_fails_the_owner_and_joins_other_workers
    started = Queue.new
    cleaned = Queue.new
    blocked = Queue.new
    runner = Thread.new do
      Net::Connector::Concurrency::Pool.new(concurrency: 2).map([1, 2]) do
        started << Thread.current
        begin
          blocked.pop
        ensure
          cleaned << Thread.current
        end
      end
    rescue RuntimeError => error
      error
    end
    Timeout.timeout(5) do
      workers = 2.times.map { started.pop }
      workers.first.kill
      assert_instance_of RuntimeError, runner.value
      assert workers.none?(&:alive?)
      assert_equal workers.sort_by(&:object_id), 2.times.map { cleaned.pop }.sort_by(&:object_id)
    end
  ensure
    runner&.kill
    runner&.join
  end

  def test_nil_task_results_remain_valid
    assert_equal [nil, nil], Net::Connector::Concurrency::Pool.new(concurrency: 1).map([1, 2]) { nil }
  end
end
