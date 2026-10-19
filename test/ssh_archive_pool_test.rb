# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "timeout"
require_relative "../lib/net/connector/netdisco/ssh/archive/pool"

class SshArchivePoolTest < Minitest::Test
  T = Net::Connector::Netdisco::SSH::Archive

  def test_connection_preflight_is_parallel_but_bounded
    entered, release = Queue.new, Queue.new
    mutex = Mutex.new
    active = peak = prepared = 0
    factory = lambda do |**|
      Object.new.tap do |archive|
        archive.define_singleton_method(:prepare) do
          mutex.synchronize { active += 1; peak = [peak, active].max }
          entered << true
          release.pop
          mutex.synchronize { prepared += 1 }
        ensure
          mutex.synchronize { active -= 1 }
        end
        archive.define_singleton_method(:close) {}
      end
    end
    pool = T::Client.stub(:new, factory) do
      T::Pool.new(directory: "unused", root: "unused", password: nil, parallel: 20)
    end
    runner = Thread.new { pool.prepare }
    Timeout.timeout(2) { 4.times { entered.pop } }
    assert_equal 4, peak
    5.times { release << true }
    runner.value
    assert_equal 5, prepared
    assert_equal 4, peak
  ensure
    5.times { release << true } if release
    runner&.kill
    runner&.join
    pool&.close
  end

  def test_preflight_failure_closes_every_connection_without_replacing_primary_error
    failure = IOError.new("preflight failed")
    closed = Queue.new
    index = 0
    factory = lambda do |**|
      number = index
      index += 1
      Object.new.tap do |archive|
        archive.define_singleton_method(:prepare) { raise failure if number.zero? }
        archive.define_singleton_method(:close) do
          closed << number
          raise IOError, "cleanup failed"
        end
      end
    end
    pool = T::Client.stub(:new, factory) do
      T::Pool.new(directory: "unused", root: "unused", password: nil, parallel: 5)
    end
    assert_same failure, assert_raises(IOError) { pool.prepare }
    assert_equal [0, 1], (2.times.map { closed.pop(true) })
  end

  def test_batch_parallelism_is_distributed_without_exceeding_each_connection_limit
    entered, release = Queue.new, Queue.new
    counts, peaks, prepared, closed = [], [], [], []
    mutex = Mutex.new
    factory = lambda do |**|
      index = counts.size
      counts << 0
      peaks << 0
      archive = Object.new
      archive.define_singleton_method(:prepare) { prepared << index }
      archive.define_singleton_method(:close) { closed << index }
      archive.define_singleton_method(:upload_and_archive) do |device, **|
        mutex.synchronize do
          counts[index] += 1
          peaks[index] = [peaks[index], counts[index]].max
        end
        entered << true
        release.pop
        device
      ensure
        mutex.synchronize { counts[index] -= 1 }
      end
      archive
    end
    pool = T::Client.stub(:new, factory) do
      T::Pool.new(directory: "unused", root: "unused", password: nil, parallel: 10)
    end
    pool.prepare
    threads = 10.times.map { |index| Thread.new { pool.upload_and_archive(index, started_at: Time.now.utc) } }
    Timeout.timeout(3) { 10.times { entered.pop } }
    assert_equal [4, 4, 2], peaks
    assert_equal [0, 1, 2], prepared
    10.times { release << true }
    assert_equal (0...10).to_a, threads.map(&:value)
    pool.close
    assert_equal [0, 1, 2], closed
  ensure
    10.times { release << true } if release
    threads&.each { |thread| thread.kill; thread.join }
  end

  def test_close_attempts_all_connections_and_preserves_first_failure
    failure = IOError.new("first close failure")
    archives = 2.times.map { Object.new }
    archives.first.define_singleton_method(:close) { raise failure }
    closed = false
    archives.last.define_singleton_method(:close) { closed = true }
    pool = T::Client.stub(:new, ->(**) { archives.shift }) do
      T::Pool.new(directory: "unused", root: "unused", password: nil, parallel: 5)
    end
    assert_same failure, assert_raises(IOError) { pool.close }
    assert closed
  end
end
