# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/net/connector/netdisco/inventory/cache"

class InventoryCacheModesTest < Minitest::Test
  Inventory = Net::Connector::Netdisco::Inventory
  Cache = Inventory::Cache

  def setup
    @root = Dir.mktmpdir
    @directory = File.join(@root, "cache")
    @now = Time.utc(2026, 10, 18)
    @rows = [{ "ip" => "192.0.2.1", "vendor" => "H3C" }]
    @remote = Object.new
    rows = @rows
    @remote.define_singleton_method(:devices) { rows }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def cache(**options)
    Cache.new(inventory: @remote, directory: @directory, identity: "mode-tests", clock: -> { @now }, **options)
  end

  def seed
    cache.devices
    @path = Dir.glob(File.join(@directory, "*.json")).fetch(0)
    File.unlink(Dir.glob(File.join(@directory, "*.lock")).fetch(0))
  end

  def forbid_remote
    @remote.define_singleton_method(:devices) { raise "remote must not be called" }
  end

  def files
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).reject { |path| [".", ".."].include?(File.basename(path)) }
       .to_h { |path| [path, [File.lstat(path).mode, File.lstat(path).mtime, File.lstat(path).ctime, File.file?(path) ? File.binread(path) : nil]] }
  end

  def assert_unavailable(instance = cache)
    error = assert_raises(Inventory::Error) { instance.devices(cache_mode: :only) }
    assert_equal :cache_unavailable, error.code
    assert_nil error.cause
    refute_includes error.message, @root
    refute_includes error.message, "secret"
  end

  def test_offline_factory_defaults_to_only_and_cannot_be_switched_to_writing_modes
    instance = Cache.offline(directory: @directory, identity: "mode-tests", clock: -> { @now })
    error = assert_raises(Inventory::Error) { instance.devices }
    assert_equal :cache_unavailable, error.code
    refute File.exist?(@directory)
    assert_raises(ArgumentError) { instance.devices(cache_mode: :prefer) }
    assert_raises(ArgumentError) { instance.devices(cache_mode: :refresh) }
    refute File.exist?(@directory)
    seed
    @now += Cache::DEFAULT_TTL
    before = files
    assert_equal @rows, instance.devices
    assert_equal :stale_cache, instance.status
    assert_nil instance.refresh_error_code
    assert_equal before, files
  end

  def test_only_delivers_fresh_validated_cache_without_lock_or_write
    seed
    forbid_remote
    before = files
    instance = cache
    assert_equal @rows, instance.devices(cache_mode: :only)
    assert_equal :fresh_cache, instance.status
    assert_equal @now, instance.fetched_at
    assert_nil instance.refresh_error_code
    assert_equal before, files
  end

  def test_only_delivers_expired_cache_without_remote_or_mutation
    seed
    forbid_remote
    before = files
    @now += Cache::DEFAULT_TTL
    instance = cache
    assert_equal @rows, instance.devices(cache_mode: "only")
    assert_equal :stale_cache, instance.status
    assert_equal @now - Cache::DEFAULT_TTL, instance.fetched_at
    assert_nil instance.refresh_error_code
    assert_nil instance.write_error_type
    assert_equal before, files
  end

  def test_only_missing_directory_does_not_create_it
    forbid_remote
    assert_unavailable
    refute File.exist?(@directory)
    assert_empty Dir.children(@root)
  end

  def test_only_missing_file_does_not_create_lock
    Dir.mkdir(@directory, 0o700)
    forbid_remote
    before = files
    assert_unavailable
    assert_equal before, files
  end

  def test_only_rejects_invalid_contents_without_repair_or_remote
    seed
    forbid_remote
    valid = JSON.parse(File.binread(@path))
    invalid = ["secret invalid json", '{"rows":[[[[[0]]]]]}',
               JSON.generate(valid.merge("schema" => 2)),
               JSON.generate(valid.merge("identity" => "other")),
               JSON.generate(valid.merge("fetched_at" => @now.to_f + 1)),
               JSON.generate(valid.merge("rows" => [{ "ip" => "" }])),
               JSON.generate(valid.merge("rows" => [{ "ip" => "192.0.2.1", "name" => 1 }]))]
    invalid.each do |body|
      File.binwrite(@path, body)
      before = files
      assert_unavailable
      assert_equal before, files
    end
  end

  def test_only_enforces_byte_and_device_limits
    seed
    forbid_remote
    assert_unavailable(cache(max_inventory_bytes: File.size(@path) - 1))
    entry = JSON.parse(File.binread(@path))
    File.binwrite(@path, JSON.generate(entry.merge("rows" => @rows * 2)))
    assert_unavailable(cache(max_devices: 1))
  end

  def test_only_rejects_unsafe_file_and_directory_permissions_without_chmod
    seed
    forbid_remote
    File.chmod(0o644, @path)
    before = files
    assert_unavailable
    assert_equal before, files
    File.chmod(0o600, @path)
    File.chmod(0o755, @directory)
    before = files
    assert_unavailable
    assert_equal before, files
  end

  def test_only_rejects_symlink_and_hard_link_cache_entries
    seed
    forbid_remote
    target = File.join(@root, "history.json")
    File.rename(@path, target)
    File.symlink(target, @path)
    assert_unavailable
    assert File.symlink?(@path)
    File.unlink(@path)
    File.link(target, @path)
    assert_unavailable
    assert_equal 2, File.stat(target).nlink
  end

  def test_prefer_default_and_string_mode_use_fresh_cache
    seed
    forbid_remote
    instance = cache
    assert_equal @rows, instance.devices
    assert_equal :fresh_cache, instance.status
    assert_equal @rows, instance.devices(cache_mode: "prefer")
    assert_equal :fresh_cache, instance.status
  end

  def test_refresh_mode_bypasses_fresh_cache
    seed
    @remote.define_singleton_method(:devices) { [{ "ip" => "192.0.2.2" }] }
    instance = cache
    assert_equal [{ "ip" => "192.0.2.2" }], instance.devices(cache_mode: "refresh")
    assert_equal :refreshed, instance.status
    assert_equal [{ "ip" => "192.0.2.2" }], cache.devices(cache_mode: :only)
  end

  def test_refresh_failure_delivers_history_and_only_clears_error_metadata
    seed
    @remote.define_singleton_method(:devices) { raise Inventory::Timeout }
    instance = cache
    assert_equal @rows, instance.devices(cache_mode: :refresh)
    assert_equal :stale_cache, instance.status
    assert_equal :inventory_timeout, instance.refresh_error_code
    assert_equal @rows, instance.devices(cache_mode: :only)
    assert_equal :fresh_cache, instance.status
    assert_nil instance.refresh_error_code
  end

  def test_invalid_modes_and_conflicting_force_refresh_fail_before_filesystem_or_remote
    forbid_remote
    [nil, false, 1, :unknown, "ONLY", " prefer ", Object.new].each do |mode|
      error = assert_raises(ArgumentError) { cache.devices(cache_mode: mode) }
      refute_includes error.message, mode.inspect unless mode.is_a?(Symbol)
    end
    [:only, "only"].each do |mode|
      assert_raises(ArgumentError) { cache.devices(cache_mode: mode, force_refresh: true) }
    end
    refute File.exist?(@directory)
    assert_empty Dir.children(@root)
  end
end
