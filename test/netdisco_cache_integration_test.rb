# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/net/connector/netdisco"

class NetdiscoCacheIntegrationTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def with_settings
    Dir.mktmpdir do |root|
      env = { "ND_URL" => "https://inventory.example/netdisco", "ND_USERNAME" => "reader", "ND_PASSWORD" => "private-value" }
      defaults = { "ND_CACHE_DIRECTORY" => File.join(root, "cache") }
      yield Netdisco::Settings.new(env: env, defaults: defaults), env, defaults
    end
  end

  def test_default_ttl_environment_parallel_and_precedence
    settings = Netdisco::Settings.new(env: { "NC_PARALLEL" => "3" }, defaults: { "NC_PARALLEL" => "2" })
    assert_equal 3, settings.snapshot.parallel
    assert_equal 5, settings.with_overrides("NC_PARALLEL" => "5").snapshot.parallel
    assert_equal 259_200, settings.snapshot.inventory_cache_options.fetch(:ttl)
    assert settings.snapshot.inventory_cache_options.fetch(:enabled)
    assert_raises(ArgumentError) { settings.with_overrides("ND_CACHE_TTL" => "NaN").snapshot }
    assert_raises(ArgumentError) { settings.with_overrides("ND_CACHE_ENABLED" => "maybe").snapshot }
  end

  def test_cache_ttl_environment_precedence_validation_and_snapshot
    env = { "ND_CACHE_TTL" => "3600" }
    settings = Netdisco::Settings.new(env: env, defaults: { "ND_CACHE_TTL" => "7200" })
    snapshot = settings.snapshot
    assert_equal 3600, snapshot.inventory_cache_options.fetch(:ttl)
    assert_equal 1800, settings.with_overrides("ND_CACHE_TTL" => "1800").snapshot.inventory_cache_options.fetch(:ttl)
    env["ND_CACHE_TTL"] = "60"
    assert_equal 3600, snapshot.inventory_cache_options.fetch(:ttl)
    assert_equal 60, settings.snapshot.inventory_cache_options.fetch(:ttl)
    %w[0 -1 NaN Infinity invalid].each do |value|
      assert_raises(ArgumentError) { Netdisco::Settings.new(env: { "ND_CACHE_TTL" => value }).snapshot }
    end
  end

  def test_inventory_uses_environment_ttl_to_expire_existing_cache
    with_settings do |settings, env, _defaults|
      env["ND_CACHE_TTL"] = "10"
      calls = 0
      builder = lambda do |**_options|
        Object.new.tap do |inventory|
          inventory.define_singleton_method(:devices) { calls += 1; [{ "ip" => "192.0.2.1" }] }
        end
      end
      Netdisco::Inventory::HTTP.stub(:new, builder) do
        now = Time.now.utc
        Time.stub(:now, now) { settings.inventory.devices }
        Time.stub(:now, now + 2) { settings.inventory.devices }
        assert_equal 1, calls
        env["ND_CACHE_TTL"] = "1"
        Time.stub(:now, now + 2) { settings.inventory.devices }
        assert_equal 2, calls
      end
    end
  end

  def test_inventory_cache_identity_rules_rotation_and_force_refresh
    with_settings do |settings, env, defaults|
      calls = []
      rows = [{ "ip" => "192.0.2.1", "vendor" => "H3C", "extra_secret" => "must-not-persist" }]
      builder = lambda do |**options|
        Struct.new(:fetcher).new(-> { calls << options[:username]; rows }).tap do |inventory|
          inventory.define_singleton_method(:devices) { fetcher.call }
        end
      end
      Netdisco::Inventory::HTTP.stub(:new, builder) do
        fleet = Netdisco::Fleet.new(settings: settings)
        assert_equal :h3c, fleet.devices.first.vendor
        assert_equal :refreshed, fleet.inventory_status.fetch(:source)
        defaults["NC_HOST_OVERRIDES"] = '{"192.0.2.1":"huawei"}'
        assert_equal :huawei, fleet.devices.first.vendor
        assert_equal :fresh_cache, fleet.inventory_status.fetch(:source)
        assert_equal ["reader"], calls
        fleet.devices(force_refresh: true)
        assert_equal ["reader", "reader"], calls
        env["ND_USERNAME"] = "another-reader"
        fleet.devices
        assert_equal ["reader", "reader", "another-reader"], calls
        env["ND_PASSWORD"] = "rotated-private-value"
        fleet.devices
        assert_equal 3, calls.size
        files = Dir[File.join(defaults.fetch("ND_CACHE_DIRECTORY"), "*.json")]
        assert_equal 2, files.size
        serialized = files.map { |path| File.read(path) }.join
        %w[private-value must-not-persist reader].each { |text| refute_includes serialized, text }
      end
    end
  end

  def test_failed_inventory_does_not_retain_last_success_metadata
    rows = []
    inventory = Object.new
    inventory.define_singleton_method(:devices) { rows }
    fleet = Netdisco::Fleet.new(inventory: inventory, settings: Netdisco::Settings.new(env: {}))
    fleet.devices
    assert_equal :uncached, fleet.inventory_status.fetch(:source)
    inventory.define_singleton_method(:devices) { raise Netdisco::Inventory::Error, "failed" }
    assert_raises(Netdisco::Inventory::Error) { fleet.devices }
    assert_nil fleet.inventory_status
  end

  def test_offline_export_rejects_inventory_refresh_without_reading_files_or_inventory
    output = StringIO.new
    error = StringIO.new
    cli = Netdisco::CLI.new(configuration_options: { directories: [] }, argv: %w[--export 192.0.2.1 --refresh-inventory], env: {}, output: output, error: error)
    assert_equal 2, cli.run
    assert_empty output.string
    assert_includes error.string, "--export 不能与备份选项同时使用"
  end

  def test_stdin_principal_and_database_query_do_not_share_inventory
    with_settings do |settings, _env, defaults|
      calls = []
      rows = [{ "ip" => "192.0.2.1" }]
      builder = ->(**options) { calls << options; Struct.new(:devices).new(rows) }
      Netdisco::Inventory::HTTP.stub(:new, builder) do
        settings.inventory.devices
        settings.inventory(credentials: { username: "operator", password: "stdin-secret" }).devices
        assert_equal 2, Dir[File.join(defaults.fetch("ND_CACHE_DIRECTORY"), "*.json")].size
      end
      postgres = Netdisco::Settings.new(env: { "ND_DB_HOST" => "database.example", "ND_DB_NAME" => "inventory",
                                              "ND_DB_USER" => "reader", "ND_DB_PASS" => "database-secret" },
                                         defaults: defaults.merge("ND_SOURCE" => "postgres", "ND_QUERY" => "SELECT ip FROM device"))
      Netdisco::Inventory::Postgres.stub(:new, builder) do
        postgres.inventory.devices
        postgres.with_overrides("ND_QUERY_PARAMS" => '["east"]').inventory.devices
        assert_equal 4, Dir[File.join(defaults.fetch("ND_CACHE_DIRECTORY"), "*.json")].size
      end
      assert_equal 4, calls.size
    end
  end

  def test_failed_force_refresh_preserves_timestamp_and_cli_exposes_stale_source
    with_settings do |settings, _env, _defaults|
      failure = nil
      builder = lambda do |**|
        Object.new.tap do |inventory|
          inventory.define_singleton_method(:devices) do
            raise failure if failure

            [{ "ip" => "192.0.2.1", "vendor" => "H3C" }]
          end
        end
      end
      Netdisco::Inventory::HTTP.stub(:new, builder) do
        fleet = Netdisco::Fleet.new(settings: settings)
        fleet.devices
        timestamp = fleet.inventory_status.fetch(:fetched_at)
        failure = Netdisco::Inventory::Error.new("private-response", code: :connection_failed)
        assert_equal "192.0.2.1", fleet.devices(force_refresh: true).first.host
        assert_equal :stale_cache, fleet.inventory_status.fetch(:source)
        assert_equal timestamp, fleet.inventory_status.fetch(:fetched_at)
        output, error = StringIO.new, StringIO.new
        cli = Netdisco::CLI.new(configuration_options: { directories: [] }, argv: %w[--plan --refresh-inventory], env: {}, output: output, error: error,
                                fleet_factory: ->(*) { fleet })
        assert_equal 0, cli.run, error.string
        assert_includes error.string, "历史缓存"
        refute_includes error.string, "private-response"
        assert_equal "192.0.2.1", JSON.parse(output.string).fetch("selected").first.fetch("host")
      end
    end
  end
end
