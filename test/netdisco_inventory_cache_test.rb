# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "timeout"
require_relative "../lib/net/connector/netdisco/inventory/cache"

class NetdiscoInventoryCacheTest < Minitest::Test
  Cache = Net::Connector::Netdisco::Inventory::Cache

  def setup
    @directory = Dir.mktmpdir
    @now = Time.utc(2026, 10, 11)
    @calls = 0
    @rows = [{ "ip" => "192.0.2.1", "vendor" => "H3C" }]
    @failure = nil
    @inventory = Object.new
    test = self
    @inventory.define_singleton_method(:devices) { test.request }
  end

  def test_external_error_metadata_is_not_written_to_public_cache_status
    inventory = cache
    inventory.devices
    @failure = Net::Connector::Netdisco::Inventory::Error.new("private-value", code: "private-code\nsecond-line")
    inventory.devices(force_refresh: true)
    assert_equal :inventory_error, inventory.refresh_error_code
    refute_includes inventory.inspect, "private"
  end

  def test_invalid_clock_values_do_not_turn_into_zero_timestamps
    [nil, false, "bad-clock", Complex(1, 1), Float::INFINITY].each do |value|
      assert_raises(ArgumentError) { cache(clock: -> { value }).devices }
    end
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def request
    @calls += 1
    raise @failure if @failure

    @rows
  end

  def cache(**options)
    Cache.new(inventory: @inventory, directory: @directory, identity: "source-one", clock: -> { @now }, **options)
  end

  def path = Dir.glob(File.join(@directory, "*.json")).fetch(0)
  def lock_path = Dir.glob(File.join(@directory, "*.lock")).fetch(0)

  def change_entry
    entry = JSON.parse(File.read(path))
    yield entry
    File.write(path, JSON.generate(entry))
  end

  def test_default_ttl_fresh_cache_and_exact_expiration
    first = cache
    assert_equal @rows, first.devices
    assert_equal :refreshed, first.status
    assert_equal @now, first.fetched_at
    assert first.fetched_at.utc?
    @now += 259_199
    second = cache
    assert_equal @rows, second.devices
    assert_equal :fresh_cache, second.status
    assert_equal 1, @calls
    @now += 1
    assert_equal @rows, second.devices
    assert_equal :refreshed, second.status
    assert_equal 2, @calls
  end

  def test_force_refresh_bypasses_fresh_and_successful_empty_rows_replace_history
    instance = cache
    instance.devices
    @rows = []
    assert_empty instance.devices(force_refresh: true)
    assert_equal :refreshed, instance.status
    assert_empty cache.devices
    assert_equal 2, @calls
  end

  def test_expired_refresh_failure_returns_history_without_changing_timestamp
    instance = cache
    instance.devices
    original = File.binread(path)
    @now += 259_200
    @failure = Net::Connector::Netdisco::Inventory::Timeout.new
    assert_equal @rows, instance.devices
    assert_equal :stale_cache, instance.status
    assert_equal @now - 259_200, instance.fetched_at
    assert_equal :inventory_timeout, instance.refresh_error_code
    assert_equal original, File.binread(path)
    assert_equal 2, @calls
  end

  def test_force_refresh_failure_returns_fresh_history_with_explicit_stale_status
    instance = cache
    instance.devices
    @failure = Net::Connector::Netdisco::Inventory::Error.new("secret response", code: :request_failed)
    assert_equal @rows, instance.devices(force_refresh: true)
    assert_equal :stale_cache, instance.status
    assert_equal :request_failed, instance.refresh_error_code
    refute_includes instance.inspect, "secret response"
  end

  def test_refresh_failure_without_history_is_rethrown
    @failure = Net::Connector::Netdisco::Inventory::Error.new("failed", code: :connection_failed)
    assert_same @failure, assert_raises(Net::Connector::Netdisco::Inventory::Error) { cache.devices }
  end

  def test_program_errors_and_interrupt_never_fall_back
    cache.devices
    [ArgumentError.new("invalid config"), RuntimeError.new("broken callback"), Interrupt.new].each do |failure|
      @failure = failure
      assert_same failure, assert_raises(failure.class) { cache.devices(force_refresh: true) }
    end
  end

  def test_namespace_identity_isolates_histories
    cache.devices
    second = cache(identity: "source-two")
    @rows = [{ "ip" => "192.0.2.2" }]
    assert_equal @rows, second.devices
    assert_equal 2, @calls
    assert_equal 2, Dir.glob(File.join(@directory, "*.json")).size
  end

  def test_cache_only_contains_field_whitelist_and_owns_immutable_rows
    @rows.first["ip"] = @rows.first.fetch("ip").dup
    @rows.first["sensitive_extra"] = "secret-token"
    result = cache.devices
    assert_equal [{ "ip" => "192.0.2.1", "vendor" => "H3C" }], result
    refute_includes File.read(path), "secret-token"
    refute_includes File.read(path), "sensitive_extra"
    assert result.frozen?
    assert result.first.frozen?
    assert result.first.fetch("ip").frozen?
    @rows.first.fetch("ip").replace("changed")
    assert_equal "192.0.2.1", result.first.fetch("ip")
    assert_equal 0o600, File.stat(path).mode & 0o7777
    assert_equal 0o600, File.stat(lock_path).mode & 0o7777
  end

  def test_malformed_cache_is_a_miss
    cache.devices
    File.write(path, "{invalid json")
    assert_equal @rows, cache.devices
    assert_equal 2, @calls
  end

  def test_empty_cache_is_a_miss_and_is_replaced_by_a_complete_inventory
    cache.devices
    File.write(path, "")
    instance = cache
    assert_equal @rows, instance.devices
    assert_equal :refreshed, instance.status
    assert_equal 2, @calls
    assert_equal @rows, cache.devices
    assert_equal 2, @calls
  end

  def test_empty_cache_cannot_hide_a_remote_failure
    cache.devices
    File.write(path, "")
    @failure = Net::Connector::Netdisco::Inventory::Error.new("offline", code: :connection_failed)
    assert_same @failure, assert_raises(Net::Connector::Netdisco::Inventory::Error) { cache.devices }
  end

  def test_row_copy_preserves_nil_fields_and_excludes_absent_fields
    @rows = [{ "ip" => "192.0.2.1", "name" => nil, "extra" => "private" }]
    instance = cache
    [instance.devices, cache.devices].each do |rows|
      assert_equal [{ "ip" => "192.0.2.1", "name" => nil }], rows
      assert rows.frozen?
      assert rows.first.frozen?
      assert rows.first.fetch("ip").frozen?
      refute_same @rows.first.fetch("ip"), rows.first.fetch("ip")
    end
  end

  def test_future_timestamp_schema_identity_and_invalid_rows_are_misses
    mutations = [->(entry) { entry["fetched_at"] = @now.to_f + 1 },
                 ->(entry) { entry["schema"] = 2 },
                 ->(entry) { entry["identity"] = "another" },
                 ->(entry) { entry["rows"] = [{ "ip" => nil }] },
                 ->(entry) { entry["rows"] = [{ "ip" => "192.0.2.1", "name" => 3 }] },
                 ->(entry) { entry["unexpected"] = true }]
    cache.devices
    mutations.each do |mutation|
      change_entry(&mutation)
      instance = cache
      assert_equal @rows, instance.devices
      assert_equal :refreshed, instance.status
    end
    assert_equal 7, @calls
  end

  def test_changed_max_devices_does_not_allow_fallback_to_over_limit_history
    @rows = [{ "ip" => "192.0.2.1" }, { "ip" => "192.0.2.2" }]
    cache.devices
    @failure = Net::Connector::Netdisco::Inventory::Error.new("offline")
    assert_raises(Net::Connector::Netdisco::Inventory::Error) { cache(max_devices: 1).devices }
  end

  def test_changed_byte_limit_does_not_allow_fallback_to_over_limit_history
    cache.devices
    @failure = Net::Connector::Netdisco::Inventory::Error.new("offline")
    assert_raises(Net::Connector::Netdisco::Inventory::Error) { cache(max_inventory_bytes: 10).devices }
  end

  def test_invalid_remote_rows_do_not_overwrite_history
    instance = cache
    instance.devices
    original = File.binread(path)
    @rows = [{ "ip" => "" }]
    assert_equal [{ "ip" => "192.0.2.1", "vendor" => "H3C" }], instance.devices(force_refresh: true)
    assert_equal :invalid_inventory, instance.refresh_error_code
    assert_equal original, File.binread(path)
  end

  def test_invalid_remote_rows_without_history_raise_inventory_error
    @rows = [{ "ip" => "192.0.2.1", "vendor" => Object.new }]
    assert_equal :invalid_inventory, assert_raises(Net::Connector::Netdisco::Inventory::Error) { cache.devices }.code
  end

  def test_successful_remote_read_survives_cache_write_error
    writer = Net::Connector::Storage::AtomicFile
    writer.stub(:write, ->(*) { raise IOError, "filesystem detail" }) do
      instance = cache
      assert_equal @rows, instance.devices
      assert_equal :refreshed, instance.status
      assert_equal "IOError", instance.write_error_type
      refute_includes instance.inspect, "filesystem detail"
    end
  end

  def test_status_errors_are_reset_after_success
    instance = cache
    instance.devices
    @failure = Net::Connector::Netdisco::Inventory::Error.new("offline", code: :connection_failed)
    instance.devices(force_refresh: true)
    @failure = nil
    instance.devices(force_refresh: true)
    assert_nil instance.refresh_error_code
    assert_nil instance.write_error_type
    assert_equal :refreshed, instance.status
  end

  # 已提交的新文件不能因目录同步失败被当成旧历史，亦不能触发第二次远端调用。
  def test_post_commit_write_failure_keeps_new_rows_and_cache
    writer = Net::Connector::Storage::AtomicFile
    original = writer.method(:write)
    replacement = lambda do |*arguments|
      receipt = original.call(*arguments)
      raise writer::PersistenceError.new(receipt: receipt.with(state: :committed, phase: :directory_sync),
                                         underlying_type: "IOError")
    end
    writer.stub(:write, replacement) do
      instance = cache
      assert_equal @rows, instance.devices
      assert_equal :refreshed, instance.status
      assert_equal writer::PersistenceError.name, instance.write_error_type
    end
    assert_equal @rows, cache.devices
    assert_equal 1, @calls
  end

  def test_unsafe_directory_is_rejected_before_remote_read
    File.chmod(0o755, @directory)
    assert_raises(Cache::Error) { cache.devices }
    assert_equal 0, @calls
  end

  def test_directory_symlink_is_rejected
    target = File.join(@directory, "actual")
    Dir.mkdir(target, 0o700)
    link = File.join(@directory, "alias")
    File.symlink(target, link)
    assert_raises(Cache::Error) { cache(directory: link).devices }
    assert_equal 0, @calls
  end

  def test_nonexistent_directory_is_created_privately
    directory = File.join(@directory, "nested")
    assert_equal @rows, cache(directory: directory).devices
    assert_equal 0o700, File.stat(directory).mode & 0o7777
  end

  def test_cache_symlink_and_hardlink_are_rejected
    cache.devices
    original = File.binread(path)
    target = File.join(@directory, "target")
    File.rename(path, target)
    name = File.join(@directory, "#{Digest::SHA256.hexdigest("source-one")}.json")
    File.symlink(target, name)
    assert_raises(Cache::Error) { cache.devices }
    File.unlink(name)
    File.link(target, name)
    assert_raises(Cache::Error) { cache.devices }
    assert_equal original, File.binread(target)
    assert_equal 1, @calls
  end

  def test_non_private_cache_or_lock_permissions_are_rejected
    cache.devices
    File.chmod(0o644, path)
    assert_raises(Cache::Error) { cache.devices }
    File.chmod(0o600, path)
    File.chmod(0o644, lock_path)
    assert_raises(Cache::Error) { cache.devices(force_refresh: true) }
  end

  def test_lock_wait_is_bounded_and_releases_after_busy_failure
    cache.devices
    File.open(lock_path, File::RDWR) do |file|
      file.flock(File::LOCK_EX)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Cache::Busy) { cache(lock_timeout: 0.02).devices(force_refresh: true) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    end
    assert_equal @rows, cache.devices(force_refresh: true)
  end

  # 两个独立实例竞争同一缓存时，后获得锁者必须看到首次完整刷新的结果。
  def test_concurrent_cache_miss_fetches_only_once
    entered = Queue.new
    release = Queue.new
    calls = 0
    inventory = Object.new
    inventory.define_singleton_method(:devices) do
      calls += 1
      entered << true
      release.pop
      [{ "ip" => "192.0.2.1" }]
    end
    first = Thread.new { cache(inventory: inventory).devices }
    Timeout.timeout(2) { entered.pop }
    second = Thread.new { cache(inventory: inventory).devices }
    release << true
    assert_equal first.value, second.value
    assert_equal 1, calls
  ensure
    release << true if release
    first&.join
    second&.join
  end

  def test_zero_ttl_always_refreshes_and_zero_lock_timeout_is_allowed
    instance = cache(ttl: 0, lock_timeout: 0)
    2.times { instance.devices }
    assert_equal 2, @calls
  end

  # flock 必须跨进程仲裁，而不只是同进程线程的互斥。
  def test_concurrent_processes_fetch_only_once
    marker = File.join(@directory, "remote-calls")
    children = 2.times.map do
      fork do
        inventory = Object.new
        inventory.define_singleton_method(:devices) do
          File.open(marker, "a", 0o600) { |file| file.puts("called") }
          sleep(0.15)
          [{ "ip" => "192.0.2.1" }]
        end
        begin
          rows = cache(inventory: inventory).devices
          exit!(rows == [{ "ip" => "192.0.2.1" }] ? 0 : 1)
        rescue StandardError
          exit!(1)
        end
      end
    end
    children.each do |pid|
      _child, status = Process.wait2(pid)
      assert status.success?
    end
    assert_equal ["called\n"], File.readlines(marker)
  ensure
    children&.each do |pid|
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def test_invalid_options_are_rejected_without_io
    [0, -1, 1.5, nil].each do |value|
      assert_raises(ArgumentError) { cache(max_devices: value) }
      assert_raises(ArgumentError) { cache(max_inventory_bytes: value) }
    end
    [-1, Float::INFINITY, Float::NAN, "3", nil].each do |value|
      assert_raises(ArgumentError) { cache(ttl: value) }
      assert_raises(ArgumentError) { cache(lock_timeout: value) }
    end
    assert_raises(ArgumentError) { cache(identity: "") }
    assert_raises(ArgumentError) { cache(directory: "") }
    assert_raises(ArgumentError) { cache(inventory: Object.new) }
    assert_raises(ArgumentError) { cache.devices(force_refresh: nil) }
    assert_equal 0, @calls
    assert_empty Dir.children(@directory)
  end
end
