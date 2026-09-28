# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class NetdiscoSettingsTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  Settings = Netdisco::Settings

  def test_snapshot_preserves_explicit_nil_and_false_over_defaults
    settings = Settings.new(env: {}, defaults: { "NC_SAMPLE_PER_VENDOR" => "3",
                                                "NETDISCO_ALLOW_INSECURE_HTTP" => "true" },
                            overrides: { "NC_SAMPLE_PER_VENDOR" => nil, "NETDISCO_ALLOW_INSECURE_HTTP" => false })
    policy = settings.for_run
    assert_nil policy.limit_per_vendor(tftp: true)
    assert_equal false, policy.client_options.fetch(:allow_insecure_http)
    assert_equal false, policy.public_config.fetch(:netdisco).fetch(:allow_insecure_http)
    assert_equal 5, Settings.new(env: {}).limit_per_vendor(tftp: true)
    [nil, false].each do |value|
      error = assert_raises(ArgumentError) { Settings.new(env: {}, overrides: { "NC_CONCURRENCY" => value }).snapshot }
      assert_equal "NC_CONCURRENCY must be a positive integer", error.message
      assert_nil error.cause
    end
  end

  def test_client_budget_errors_precede_source_specific_query_errors
    %w[http postgres].each do |source|
      settings = Settings.new(env: {}, defaults: { "NETDISCO_SOURCE" => source, "NETDISCO_PAGE_SIZE" => "0",
                                                  "NETDISCO_QUERY_PARAMS" => "not-json" })
      error = assert_raises(ArgumentError) { settings.client_options }
      assert_equal "NETDISCO_PAGE_SIZE must be a positive integer", error.message
      assert_nil error.cause
    end
  end

  def rows
    [1, 2].map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
  end

  def successful_connector
    Object.new.tap do |connector|
      connector.define_singleton_method(:backup) do |path:|
        Net::Connector::Backup.new(path: path, bytes: 1, sha256: "test", collected_at: Time.now.utc)
      end
      connector.define_singleton_method(:close) {}
    end
  end

  def cli(env, argv = ["--show-config"], &factory)
    output = StringIO.new
    error = StringIO.new
    result = Netdisco::CLI.new(argv: argv, env: env, output: output, error: error,
                               fleet_factory: factory || ->(*) { raise "must stay offline" }).run
    [result, output.string, error.string]
  end

  def test_policy_snapshot_copies_only_non_secret_values_and_is_immutable
    secret = "generated-#{rand(1_000_000)}"
    env = { "NC_PROTOCOL" => +"ssh", "NC_CONCURRENCY" => "2",
            "NC_DEVICE_USERNAME" => secret, "NC_DEVICE_PASSWORD" => secret,
            "NETDISCO_API_KEY" => secret, "NETDISCO_URL" => "https://inventory.example",
            "UNRELATED_SECRET" => secret }
    settings = Settings.new(env: env)
    policy = settings.snapshot(mode: :backup)
    assert_predicate policy, :frozen?
    assert_equal :ssh, policy.connection_options(:h3c).fetch(:protocol)
    env.fetch("NC_PROTOCOL").replace("telnet")
    env["NC_CONCURRENCY"] = "3"
    assert_equal :ssh, policy.connection_options(:h3c).fetch(:protocol)
    assert_equal 2, policy.concurrency
    assert_equal :telnet, settings.snapshot(mode: :backup).connection_options(:h3c).fetch(:protocol)
    assert_equal 3, settings.snapshot(mode: :backup).concurrency
    [policy.inspect, Marshal.dump(policy), policy.public_config.to_json, settings.inspect].each do |text|
      refute_includes text, secret
    end
    assert_raises(FrozenError) { policy.connection_options(:h3c)[:protocol] = :telnet }
  end

  def test_running_batch_keeps_policy_but_reads_credentials_for_each_device
    Dir.mktmpdir do |directory|
      env = { "NC_CONCURRENCY" => "1", "NC_PROTOCOL" => "ssh",
              "NC_DEVICE_USERNAME" => "first", "NC_DEVICE_PASSWORD" => "first-pass",
              "NC_LOG_DIRECTORY" => File.join(directory, "logs-one") }
      defaults = { "NC_MAX_SCRIPT_OUTPUT_BYTES" => "1024" }
      seen = []
      factory = lambda do |device, options|
        seen << [device.host, options]
        successful_connector
      end
      fleet = Netdisco::Fleet.new(settings: Settings.new(env: env, defaults: defaults), client: Struct.new(:devices).new(rows),
                                  connector_factory: factory, result_store: nil)
      rotate = lambda do |_result|
        defaults.merge!("NC_MAX_SCRIPT_OUTPUT_BYTES" => "2048", "NC_EXCLUDE_HOSTS" => "192.0.2.1")
        env.merge!("NC_PROTOCOL" => "telnet", "NC_CONCURRENCY" => "2",
                   "NC_HOST_KEY_POLICY" => "accept_new", "NC_LOG_LEVEL" => "warn",
                   "NC_DEVICE_USERNAME" => "second", "NC_DEVICE_PASSWORD" => "second-pass",
                   "NC_LOG_DIRECTORY" => File.join(directory, "logs-two"))
      end
      assert fleet.backup_all(directory: directory, on_result: rotate).success?
      assert_equal ["first-pass", "second-pass"], (seen.map { |_host, options| options.fetch(:password) })
      assert_equal ["first", "second"], (seen.map { |_host, options| options.fetch(:username) })
      seen.each do |_host, options|
        assert_equal :ssh, options.fetch(:protocol)
        assert_equal :strict, options.fetch(:host_key_policy)
        assert_equal :info, options.fetch(:log_level)
        assert_equal 1024, options.fetch(:max_script_output_bytes)
        assert_equal File.join(directory, "logs-one"), File.dirname(options.fetch(:log_file))
      end
      seen.clear
      batch = fleet.backup_all(directory: directory)
      assert_equal [:filtered, :backed_up], batch.outcomes.map(&:status)
      assert_equal ["192.0.2.2"], seen.map(&:first)
      options = seen.first.last
      assert_equal :telnet, options.fetch(:protocol)
      assert_equal :accept_new, options.fetch(:host_key_policy)
      assert_equal :warn, options.fetch(:log_level)
      assert_equal 2048, options.fetch(:max_script_output_bytes)
      assert_equal File.join(directory, "logs-two"), File.dirname(options.fetch(:log_file))
    end
  end

  def test_plan_captures_rules_before_inventory_io_and_execution_does_not_refetch
    env = { "NC_INCLUDE_HOSTS" => "192.0.2.1" }
    fetched = 0
    inventory = rows
    client = Object.new
    client.define_singleton_method(:devices) do
      fetched += 1
      env["NC_INCLUDE_HOSTS"] = "192.0.2.2"
      inventory
    end
    requested = []
    fleet = Netdisco::Fleet.new(settings: Settings.new(env: {}, defaults: env), client: client, result_store: nil,
                                credentials: ->(device) { requested << device.host; nil })
    plan = fleet.plan_backup
    assert_equal ["192.0.2.1"], plan.selected.map(&:host)
    Dir.mktmpdir do |directory|
      fleet.backup_all(directory: directory, plan: plan)
      assert_equal 1, fetched
      assert_equal ["192.0.2.1"], requested
    end
    assert_equal ["192.0.2.2"], fleet.plan_backup.selected.map(&:host)
    assert_equal 2, fetched
  end

  def test_client_policy_and_api_credentials_are_refreshed_between_batches
    env = { "NETDISCO_URL" => "https://inventory.example", "NETDISCO_API_KEY" => "first" }
    defaults = { "NETDISCO_MAX_DEVICES" => "7" }
    seen = []
    builder = ->(**options) { seen << options; Struct.new(:devices).new([]) }
    Netdisco::Client.stub(:new, builder) do
      fleet = Netdisco::Fleet.new(settings: Settings.new(env: env, defaults: defaults), result_store: nil)
      2.times do |index|
        fleet.devices
        env["NETDISCO_API_KEY"] = "second"
        defaults["NETDISCO_MAX_DEVICES"] = (index + 8).to_s
      end
    end
    assert_equal %w[first second], (seen.map { |options| options.fetch(:api_key) })
    assert_equal [7, 8], (seen.map { |options| options.fetch(:max_devices) })
  end

  def test_show_config_validates_enums_ranges_and_combinations_before_factory
    invalid = {
      "NC_PROTOCOL" => "invalid", "NC_H3C_PROTOCOL" => "invalid",
      "NC_LOG_LEVEL" => "trace", "NC_HOST_KEY_POLICY" => "disabled",
      "NC_SAMPLE_PER_VENDOR" => "6", "NC_CONCURRENCY" => "51",
      "NETDISCO_MAX_PAGES" => "0", "NETDISCO_MAX_DEVICES" => "-1",
      "NETDISCO_MAX_RESPONSE_BYTES" => "1.5", "NETDISCO_MAX_INVENTORY_BYTES" => "0",
      "NETDISCO_INVENTORY_TIMEOUT" => "Infinity", "NETDISCO_ALLOW_INSECURE_HTTP" => "maybe",
      "NC_MAX_SCRIPT_OUTPUT_BYTES" => "0",
      "NC_TFTP_VRFS" => '{"h3c":"not-supported"}',
      "NC_H3C_TFTP_SOURCE_FILE" => "../bad.cfg"
    }
    invalid.each do |key, value|
      assert_raises(ArgumentError) { Settings.new(env: {}, defaults: { key => value }).snapshot } unless key == "NC_H3C_PROTOCOL"
      status, output, error = cli({ key => value })
      assert_equal 2, status, "#{key}: #{error}"
      assert_empty output
      refute_empty error
    end
    assert_equal 2, cli({ "NC_HOST_KEY_POLICY" => "replace" }).first
    assert_equal 0, cli({ "NC_HOST_KEY_POLICY" => "replace",
                          "NC_KNOWN_HOSTS" => "test-known-hosts" }).first
    assert_equal 2, cli({ "NETDISCO_URL" => "http://inventory.example", "NETDISCO_ALLOW_INSECURE_HTTP" => "false" }).first
    assert_equal 0, cli({}).first
  end

  def test_invalid_settings_and_cli_sampling_fail_before_inventory_and_credentials
    calls = []
    ["--plan", "--tftp"].each do |mode|
      status, = cli({ "NC_PROTOCOL" => "invalid" }, [mode]) { calls << :factory }
      assert_equal 2, status
    end
    status, = cli({}, %w[--plan --limit-per-vendor 6]) { calls << :factory }
    assert_equal 2, status
    assert_empty calls
  end

  def test_yaml_env_cli_precedence_includes_budgets_and_preserves_credential_rotation
    Dir.mktmpdir do |directory|
      path = File.join(directory, "settings.yml")
      File.write(path, <<~YAML)
        netdisco:
          url: https://inventory.example
          max_response_bytes: 512
          max_inventory_bytes: 4096
          max_devices: 20
          max_pages: 3
          inventory_timeout: 2.5
          allow_insecure_http: false
        backup:
          concurrency: 2
          limit_per_vendor: 3
        ssh:
          max_script_output_bytes: 1024
      YAML
      env = { "NC_CONCURRENCY" => "4",
              "NC_DEVICE_USERNAME" => "reader", "NC_DEVICE_PASSWORD" => "first" }
      settings = Settings.from_file(path, env: env)
      policy = settings.snapshot(mode: :backup)
      assert_equal 2.5, policy.client_options.fetch(:inventory_timeout)
      assert_equal 20, policy.client_options.fetch(:max_devices)
      assert_equal false, policy.client_options.fetch(:allow_insecure_http)
      assert_equal 1024, policy.connection_options.fetch(:max_script_output_bytes)
      env["NC_DEVICE_PASSWORD"] = "second"
      device = Netdisco::Device.from_row(rows.first, rules: policy.rules)
      assert_equal "second", settings.device_credentials_for(device).fetch(:password)
      status, output, error = cli(env, ["--config", path, "--show-config", "--concurrency", "5", "--limit-per-vendor", "1",
                                       "--max-script-output-bytes", "4096"])
      assert_equal 0, status, error
      values = JSON.parse(output)
      assert_equal 5, values.fetch("backup").fetch("concurrency")
      assert_equal 1, values.fetch("backup").fetch("limit_per_vendor")
      assert_equal 20, values.fetch("netdisco").fetch("max_devices")
      assert_equal 4096, values.fetch("ssh").fetch("max_script_output_bytes")
      refute_includes output, "second"
    end
  end

  def test_export_help_and_version_remain_offline_with_irrelevant_invalid_network_settings
    env = { "NETDISCO_URL" => "invalid", "NETDISCO_MAX_DEVICES" => "0", "NC_PROTOCOL" => "invalid",
            "NC_MAX_SCRIPT_OUTPUT_BYTES" => "invalid" }
    [%w[--help], %w[--version]].each { |argv| assert_equal 0, cli(env, argv).first }
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "192.0.2.1.txt"), "synthetic configuration\n")
      status, output, error = cli(env, ["--export", "192.0.2.1", "--directory", directory])
      assert_equal 0, status, error
      assert_equal "synthetic configuration\n", output
    end
  end

  def test_optional_script_budget_omits_defaults_and_can_be_disabled_in_yaml
    refute Settings.new(env: {}).connection_options.key?(:max_script_output_bytes)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "settings.yml")
      File.write(path, "ssh:\n  max_script_output_bytes: null\n")
      settings = Settings.from_file(path, env: {})
      refute settings.snapshot.connection_options.key?(:max_script_output_bytes)
      ["-1", "0", "1.5", "bad"].each do |value|
        status, = cli({}, ["--plan", "--max-script-output-bytes", value]) { flunk "invalid budget must precede Fleet" }
        assert_equal 2, status
      end
      status, = cli({}, ["--export", "192.0.2.1", "--max-script-output-bytes", "1024"])
      assert_equal 2, status
    end
  end

  def test_nc_config_loads_yaml_and_keeps_common_environment_precedence
    Dir.mktmpdir do |directory|
      path = File.join(directory, "backup.yml")
      File.write(path, <<~YAML)
        backup:
          concurrency: 2
        inventory:
          include_hosts: [192.0.2.1]
        netdisco:
          max_devices: 8
        ssh:
          vendor_protocols: {h3c: telnet}
          max_script_output_bytes: 1024
        tftp:
          vrfs: {cisco_nxos: backup}
      YAML
      env = { "NC_CONFIG" => path, "NC_CONCURRENCY" => "3" }
      settings = Settings.from_env(env: env).snapshot
      assert_equal 3, settings.concurrency
      assert_equal 8, settings.client_options.fetch(:max_devices)
      assert_equal :telnet, settings.connection_options(:h3c).fetch(:protocol)
      assert_equal :ssh, settings.connection_options(:huawei).fetch(:protocol)
      assert_equal 1024, settings.connection_options.fetch(:max_script_output_bytes)
      assert_equal ["192.0.2.1"], settings.public_config.fetch(:inventory).fetch(:include_hosts)
      assert_equal({ cisco_nxos: "backup" }, settings.tftp_vrfs)
      assert_equal 0, cli(env).first
    end
  end

  def test_legacy_and_removed_environment_settings_fail_without_echoing_values
    keys = Netdisco::ConfigFile::FIELDS.values.flat_map { |fields| fields.values.map(&:first) } - Settings::ENVIRONMENT_KEYS
    keys += %w[NC_H3C_PROTOCOL NET_CONNECTOR_DEVICE_PASSWORD]
    keys.each do |key|
      status, output, error = cli({ key => "private-value" })
      assert_equal 2, status, key
      assert_empty output
      assert_includes error, key
      refute_includes error, "private-value"
      assert_match(/NC_CONFIG|renamed to NC_DEVICE_PASSWORD/, error)
    end
  end

  def test_yaml_vendor_protocols_validate_names_and_protocols
    [{ "unknown" => "ssh" }, { "h3c" => "invalid" }].each do |protocols|
      settings = Settings.new(env: {}, defaults: { "NC_VENDOR_PROTOCOLS" => JSON.generate(protocols) })
      assert_raises(ArgumentError) { settings.snapshot }
    end
  end

end
