# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/net/connector/netdisco"

class CatalogCredentialsTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_credentials_resolve_platform_precedence_without_caching_or_exposing_secrets
    env = { "NC_DEVICE_USERNAME" => +"generic-user", "NC_DEVICE_PASSWORD" => "generic-secret",
            "NC_HUAWEI_PASSWORD" => +"platform-secret", "NC_HUAWEI_ENABLE_PASSWORD" => "enable-secret" }
    resolver = Net::Connector::Credentials.new(env: env)
    first = resolver.resolve(platform: :huawei)
    assert_equal({ username: "generic-user", password: "platform-secret", enable_password: "enable-secret" }, first)
    env.fetch("NC_HUAWEI_PASSWORD").replace("rotated-secret")
    assert_equal "platform-secret", first[:password]
    assert_equal "rotated-secret", resolver.resolve(platform: :huawei)[:password]
    refute_includes resolver.inspect, "secret"
    env["NC_HUAWEI_USERNAME"] = "  "
    assert_equal "generic-user", resolver.resolve(platform: :huawei)[:username]
    env.delete("NC_DEVICE_USERNAME")
    assert_nil resolver.resolve(platform: :huawei)
    env["NC_DEVICE_USERNAME"] = false
    assert_raises(ArgumentError) { resolver.resolve(platform: :huawei) }
  end

  def test_catalog_uses_fixed_policy_and_retains_duplicates_and_invalid_rows_without_credentials
    defaults = { "NC_INCLUDE_HOSTS" => "192.0.2.1" }
    settings = N::Settings.new(env: {}, defaults: defaults)
    policy = settings.snapshot(mode: :inventory)
    defaults["NC_INCLUDE_HOSTS"] = "192.0.2.2"
    rows = [{ "ip" => +"192.0.2.1", "vendor" => "H3C" },
            { "ip" => "192.0.2.1", "vendor" => "Huawei" },
            { "ip" => "192.0.2.2", "vendor" => "H3C" },
            { "ip" => "invalid", "vendor" => "H3C" }]
    source = Struct.new(:devices).new(rows)
    catalog = N::Catalog.new(settings: settings, inventory: source)
    settings.stub(:device_credentials_for, ->(*) { flunk "must not read device credentials" }) do
      devices = catalog.devices(policy: policy)
      assert_equal [:duplicate_host, :duplicate_host, :filtered, :invalid_address], devices.map(&:issue)
      assert devices.frozen?
      assert_equal({ source: :uncached }, catalog.status)
      rows.first["ip"].replace("192.0.2.99")
      assert_equal "192.0.2.1", devices.first.host
    end
  end
end
