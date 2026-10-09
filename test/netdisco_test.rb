# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class NetdiscoTest < Minitest::Test
  Client = Net::Connector::Netdisco::Client
  Fleet = Net::Connector::Netdisco::Fleet
  Settings = Net::Connector::Netdisco::Settings

  def test_address_filters_keep_normalization_exclusion_precedence_and_input_ownership
    included = ["192.0.2.1", "192.0.2.1", "2001:db8:0:0:0:0:0:1", "192.0.2.2"].map(&:dup)
    excluded = ["192.0.2.2".dup]
    rules = Net::Connector::Netdisco::Rules.new(include_hosts: included, exclude_hosts: excluded, include_vendors: [:h3c])
    included.first.replace("192.0.2.99")
    included.clear
    excluded.first.replace("192.0.2.99")
    excluded.clear

    assert rules.selected?("192.0.2.1", :h3c)
    assert rules.selected?("2001:db8::1", :h3c)
    refute rules.selected?("192.0.2.2", :h3c)
    refute rules.selected?("192.0.2.99", :h3c)
    refute rules.selected?("192.0.2.1", :huawei)
    assert Net::Connector::Netdisco::Rules.new.selected?("192.0.2.99", :huawei)
  end

  def test_comware_and_branded_model_correct_stale_vendor_without_overriding_explicit_rules
    rules = Net::Connector::Netdisco::Rules.new
    row = { "ip" => "192.0.2.1", "vendor" => "Hillstone", "os" => "Comware", "model" => "H3C WX5540X" }
    assert_equal :h3c_wireless, rules.resolve(row)
    assert_equal :h3c_wireless, rules.resolve(row.merge("vendor" => "H3C"))
    assert_equal :h3c, rules.resolve(row.merge("model" => "H3C S6850"))
    assert_equal :hillstone, rules.resolve(row.merge("model" => "WX5540X"))
    assert_equal :hillstone, rules.resolve(row.merge("os" => "StoneOS"))
    assert_equal :hillstone, rules.resolve(row.merge("os" => nil))
    explicit = Net::Connector::Netdisco::Rules.new(vendor_overrides: { "Hillstone" => "hillstone" })
    assert_equal :hillstone, explicit.resolve(row)
    host = Net::Connector::Netdisco::Rules.new(host_overrides: { "192.0.2.1" => "hillstone" })
    assert_equal :hillstone, host.resolve(row)
    mapping = Net::Connector::Netdisco::Rules.new(mappings: [{ "vendor" => "Hillstone", "connector" => "hillstone" }])
    assert_equal :hillstone, mapping.resolve(row)
  end

  def test_named_backup_filename_sanitizes_names_and_preserves_address_identity
    rules = Net::Connector::Netdisco::Rules.new
    row = { "ip" => "192.0.2.1", "vendor" => "H3C", "name" => "core-01" }
    device = Net::Connector::Netdisco::Device.from_row(row, rules: rules)
    assert_equal "core-01-192.0.2.1.txt", device.backup_filename(style: :hostname_ip)
    assert_equal "192.0.2.1.txt", device.backup_filename
    ["../../bad/name", "\n\e[31m", "中" * 200, nil].each do |name|
      file = Net::Connector::Netdisco::Device.from_row(row.merge("name" => name), rules: rules).backup_filename(style: :hostname_ip)
      assert_equal File.basename(file), file
      assert_operator file.bytesize, :<=, 255
      assert file.valid_encoding?
      assert file.end_with?("-192.0.2.1.txt")
    end
  end

  def response(code, body)
    klass = code == "200" ? Net::HTTPOK : Net::HTTPBadRequest
    object = klass.new("1.1", code, "test")
    object.define_singleton_method(:body) { body.to_json }
    object
  end

  def test_client_authenticates_and_fetches_all_pages
    requests = []
    answers = [response("200", { api_key: "token" }), response("200", [{ ip: "192.0.2.1", vendor: "Huawei" }]),
               response("200", [])]
    requester = lambda do |uri, request|
      requests << [uri.to_s, request]
      answers.shift
    end
    client = Client.new(url: "https://inventory.example/netdisco/", username: "reader", password: "secret",
                        page_size: 1, requester: requester)
    assert_equal(["192.0.2.1"], client.devices.map { |row| row.fetch("ip") })
    assert_equal "/netdisco/login", URI(requests.first.first).path
    assert_includes requests.last.first, "offset=1"
    assert_equal "Apikey token", requests.last.last["Authorization"]
  end

  def test_client_supports_legacy_query_and_rejects_bad_or_stuck_inventory
    answers = [response("400", { error: "Missing query" }),
               response("200", [{ ip: "192.0.2.2", vendor: "Radware", snmp_comm: "secret" }])]
    queries = []
    client = Client.new(url: "https://inventory.example", api_key: "token", requester: ->(uri, _request) {
      queries << uri.query
      answers.shift
    })
    assert_equal [{ "ip" => "192.0.2.2", "vendor" => "Radware" }], client.devices
    assert_equal({ "q" => "%", "seeallcolumns" => "true" }, URI.decode_www_form(queries.last).to_h)

    repeated = [response("200", [{ ip: "192.0.2.1" }]), response("200", [{ ip: "192.0.2.1" }])]
    client = Client.new(url: "https://inventory.example", api_key: "token", page_size: 1,
                        requester: ->(_uri, _request) { repeated.shift })
    assert_raises(Client::Error) { client.devices }
    invalid = Client.new(url: "https://inventory.example", api_key: "token",
                         requester: ->(_uri, _request) { response("200", [{ ip: 123 }]) })
    assert_raises(Client::Error) { invalid.devices }
  end

  def test_rules_map_vendor_os_and_model_without_guessing_unknown_cisco
    rules = Net::Connector::Netdisco::Rules.new
    assert_equal :cisco_nxos, rules.resolve("vendor" => "Cisco Systems", "os" => "NX-OS")
    assert_equal :cisco_ios, rules.resolve("vendor" => "Cisco", "os" => "IOS XE")
    assert_nil rules.resolve("vendor" => "Cisco", "model" => "unknown")
    assert_equal :h3c_wireless, rules.resolve("vendor" => "H3C", "model" => "WX5004")
    assert_equal :palo_alto, rules.resolve("vendor" => "Palo Alto Networks")
    assert_equal :hillstone, rules.resolve("vendor" => "Hillstone Networks")
  end

  def test_settings_read_environment_defaults_and_vendor_credentials
    env = { "NETDISCO_URL" => "https://inventory.example", "NETDISCO_API_KEY" => "token",
            "NC_DEVICE_USERNAME" => "global", "NC_DEVICE_PASSWORD" => "global-secret",
            "NC_HUAWEI_USERNAME" => "huawei", "NC_HUAWEI_PASSWORD" => "vendor-secret",
            "NC_CONCURRENCY" => "2", "NC_INCLUDE_VENDORS" => "huawei",
            "NC_VENDOR_OVERRIDES" => '{"custom maker":"huawei"}',
            "NC_HOST_OVERRIDES" => '{"192.0.2.9":"h3c_wireless"}',
            "NC_DEVICE_RULES" => '[{"vendor":"Cisco","model_prefix":"CustomNX","connector":"cisco_nxos"}]' }
    policy_keys = %w[NC_INCLUDE_VENDORS NC_VENDOR_OVERRIDES NC_HOST_OVERRIDES NC_DEVICE_RULES]
    defaults = policy_keys.to_h { |key| [key, env.delete(key)] }
    settings = Settings.new(env: env, defaults: defaults)
    assert_equal 2, settings.concurrency
    assert_instance_of Client, settings.client
    device = Net::Connector::Netdisco::Device.from_row({ "ip" => "192.0.2.5", "vendor" => "custom maker" },
                                                       rules: settings.rules)
    assert_equal :huawei, device.vendor
    assert_equal "huawei", settings.device_credentials_for(device)[:username]
    assert_equal "vendor-secret", settings.device_credentials_for(device)[:password]
    env["NC_HUAWEI_PASSWORD"] = "rotated"
    assert_equal "rotated", settings.device_credentials_for(device)[:password]
    assert_equal :cisco_nxos, settings.rules.resolve("vendor" => "Cisco", "model" => "CustomNX-01")
    assert_equal :h3c_wireless, settings.rules.resolve("ip" => "192.0.2.9", "vendor" => "Hillstone")
    assert_raises(ArgumentError) do
      Net::Connector::Netdisco::Rules.new(host_overrides: { "not-an-ip" => "h3c" })
    end
  end

  def test_settings_keep_backup_modes_and_tftp_options_consistent
    settings = Settings.new(env: {})
    assert_nil settings.limit_per_vendor
    assert_equal 5, settings.limit_per_vendor(tftp: true)
    assert_equal({ huawei: "flash:/startup.cfg" }, settings.tftp_source_files)
    assert_equal({}, settings.tftp_vrfs)

    settings = Settings.new(env: { "NC_SAMPLE_PER_VENDOR" => "2" }, defaults: {
                                   "NC_H3C_TFTP_SOURCE_FILE" => "flash:/saved.cfg",
                                   "NC_TFTP_VRFS" => '{"cisco_nxos":"management"}' })
    assert_equal 2, settings.limit_per_vendor
    assert_equal 2, settings.limit_per_vendor(tftp: true)
    assert_equal "flash:/saved.cfg", settings.tftp_source_files.fetch(:h3c)
    assert_equal({ cisco_nxos: "management" }, settings.tftp_vrfs)
    assert_equal({ "cisco_nxos" => "management" }, settings.public_config.fetch(:tftp).fetch(:vrfs))
  end

  def test_backup_rejects_invalid_concurrency_before_creating_directory
    row = { "ip" => "192.0.2.1", "vendor" => "H3C" }
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]),
                      credentials: ->(_) { nil })
    Dir.mktmpdir do |root|
      directory = File.join(root, "backup")
      assert_raises(ArgumentError) { fleet.backup_all(directory: directory, concurrency: 0) }
      refute File.exist?(directory)
    end
  end

  def test_concurrency_preflight_rejects_invalid_values_before_any_batch_side_effect
    calls = []
    client = Object.new
    client.define_singleton_method(:devices) { calls << :inventory; [] }
    Dir.mktmpdir do |root|
      directory = File.join(root, "backup")
      logs = File.join(root, "logs")
      settings = Settings.new(env: { "NC_LOG_DIRECTORY" => logs })
      fleet = Fleet.new(settings: settings, client: client, result_store: nil,
                        credentials: ->(_) { calls << :credentials },
                        connector_factory: ->(*) { calls << :connector })
      [nil, false, "1", 1.0, 0, -1, Settings::MAX_CONCURRENCY + 1].each do |value|
        [[:backup_all, { directory: directory }],
         [:tftp_backup_all, { server: "192.0.2.10", report_directory: directory }]].each do |method, options|
          error = assert_raises(ArgumentError) { fleet.public_send(method, **options, concurrency: value) }
          assert_equal "concurrency must be an Integer in 1..#{Settings::MAX_CONCURRENCY}", error.message
          assert_empty calls
          refute File.exist?(directory)
          refute File.exist?(logs)
        end
      end
    end
  end

  def test_worker_accepts_both_concurrency_boundaries
    [1, Settings::MAX_CONCURRENCY].each do |value|
      worker = Net::Connector::Netdisco::Worker.new(concurrency: value)
      assert_empty worker.run([], outcomes: [], on_error: ->(*) { flunk "unexpected failure" }) { flunk "unexpected task" }
    end
  end

  def test_fleet_is_bounded_ordered_and_isolates_failures
    rows = [
      { "ip" => "192.0.2.1", "vendor" => "Huawei" },
      { "ip" => "192.0.2.2", "vendor" => "Cisco", "os" => "IOS" },
      { "ip" => "192.0.2.3", "vendor" => "unknown" },
      { "ip" => "192.0.2.4", "vendor" => "H3C" }
    ]
    lock = Mutex.new
    active = 0
    peak = 0
    closes = []
    factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:backup) do |path:|
          lock.synchronize { active += 1; peak = [peak, active].max }
          sleep 0.03
          lock.synchronize { active -= 1 }
          raise IOError, "secret must stay private" if device.host == "192.0.2.2"

          Net::Connector::Backup.new(path: path, bytes: 1, sha256: "hash", collected_at: Time.now.utc)
        end
        connector.define_singleton_method(:close) { lock.synchronize { closes << device.host } }
      end
    end
    client = Struct.new(:devices).new(rows)
    fleet = Fleet.new(result_store: nil, client: client, credentials: ->(_device) { { username: "admin", password: "secret" } },
                      connector_factory: factory)
    Dir.mktmpdir do |directory|
      batch = fleet.backup_all(directory: directory, concurrency: 2)
      assert_equal [:backed_up, :failed, :unsupported_vendor, :backed_up], batch.outcomes.map(&:status)
      assert_operator peak, :<=, 2
      assert_operator peak, :>=, 2
      assert_equal 3, closes.size
      refute batch.success?
      assert_equal "IOError", batch.outcomes[1].error_type
      refute_includes batch.outcomes[1].inspect, "secret must stay private"
    end
  end

  def test_duplicate_hosts_and_inventory_failure_never_start_backup
    rows = [{ "ip" => "192.0.2.1", "vendor" => "Huawei" },
            { "ip" => "192.0.2.1", "vendor" => "H3C" }]
    calls = 0
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      connector_factory: ->(*) { calls += 1 })
    Dir.mktmpdir do |directory|
      assert_equal [:duplicate_host, :duplicate_host],
                   fleet.backup_all(directory: directory).outcomes.map(&:status)
      assert_equal 0, calls
    end

    broken = Object.new
    broken.define_singleton_method(:devices) { raise Client::Error, "inventory unavailable" }
    fleet = Fleet.new(result_store: nil, client: broken, connector_factory: ->(*) { calls += 1 })
    assert_raises(Client::Error) { fleet.backup_all }
    assert_equal 0, calls
  end

  def test_fleet_instantiates_real_vendor_connector_and_writes_backup
    row = { "ip" => "192.0.2.20", "name" => "core-switch", "vendor" => "Cisco", "os" => "IOS XE" }
    transport = ConnectorFake.new("router#", "router#", "hostname router\nrouter#")
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]),
                      credentials: ->(_device) { { username: "admin", transport: transport } })
    Dir.mktmpdir do |directory|
      batch = fleet.backup_all(directory: directory)
      assert batch.success?, batch.outcomes.inspect
      assert_equal ["terminal length 0\n", "show running-config\n"], transport.writes
      path = File.join(directory, "192.0.2.20.txt")
      assert_equal path, batch.outcomes.first.backup.path
      assert_includes File.binread(path), "hostname router"
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_backup_filename_uses_only_address_and_keeps_names_in_metadata
    rules = Net::Connector::Netdisco::Rules.new
    device = Net::Connector::Netdisco::Device.from_row(
      { "ip" => "2001:db8::1", "name" => "  ", "dns" => "交换机 / 核心\\主机", "vendor" => "H3C" },
      rules: rules
    )
    assert_equal "2001_db8__1.txt", device.backup_filename
    assert_equal "交换机 / 核心\\主机", device.name

    fallback = Net::Connector::Netdisco::Device.from_row(
      { "ip" => "192.0.2.21", "name" => "../..", "vendor" => "H3C" }, rules: rules
    )
    assert_equal "192.0.2.21.txt", fallback.backup_filename
    assert_equal "../..", fallback.name
  end

  def test_inventory_rules_filter_before_credentials_are_requested
    rows = [{ "ip" => "192.0.2.30", "vendor" => "Huawei" },
            { "ip" => "192.0.2.31", "vendor" => "Huawei" }]
    requested = []
    rules = Net::Connector::Netdisco::Rules.new(include_hosts: ["192.0.2.30"], include_vendors: [:huawei])
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows), rules: rules,
                      credentials: ->(device) { requested << device.host; nil })
    Dir.mktmpdir do |directory|
      assert_equal [:missing_credentials, :filtered], fleet.backup_all(directory: directory).outcomes.map(&:status)
      assert_equal ["192.0.2.30"], requested
    end
  end

  def test_saved_backup_and_close_failure_are_reported_separately
    row = { "ip" => "192.0.2.40", "vendor" => "Radware" }
    connector = Object.new
    connector.define_singleton_method(:backup) do |path:|
      Net::Connector::Backup.new(path: path, bytes: 7, sha256: "digest", collected_at: Time.now.utc)
    end
    connector.define_singleton_method(:close) { raise IOError, "close failed" }
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]), credentials: ->(_) { { username: "admin" } },
                      connector_factory: ->(*) { connector })
    Dir.mktmpdir do |directory|
      outcome = fleet.backup_all(directory: directory).outcomes.first
      assert_equal :saved_with_error, outcome.status
      assert_equal "IOError", outcome.error_type
      refute_nil outcome.backup
    end
  end

  def test_tftp_batch_uses_unique_remote_names_and_prevents_palo_alto_collision
    rows = [
      { "ip" => "192.0.2.41", "name" => "交换机", "vendor" => "H3C" },
      { "ip" => "192.0.2.42", "vendor" => "Palo Alto Networks" },
      { "ip" => "192.0.2.43", "vendor" => "Palo Alto Networks" }
    ]
    calls = []
    factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:tftp_backup) do |**options|
          calls << [device.host, options]
          Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                          completed_at: Time.now.utc)
        end
        connector.define_singleton_method(:close) {}
      end
    end
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: factory)
    batch = fleet.tftp_backup_all(server: "192.0.2.10", source_files: { h3c: "flash:/startup.cfg" },
                                  concurrency: 2)
    assert_equal [:reported_uploaded, :reported_uploaded, :remote_filename_collision],
                 batch.outcomes.map(&:status)
    by_host = calls.to_h
    assert_equal "h3c-192.0.2.41.cfg", by_host.fetch("192.0.2.41").fetch(:path)
    assert_equal "flash:/startup.cfg", by_host.fetch("192.0.2.41").fetch(:source_file)
    assert_equal "running-config.xml", by_host.fetch("192.0.2.42").fetch(:path)
    refute batch.success?
  end

  def test_tftp_batch_caps_each_vendor_before_requesting_credentials
    rows = (1..6).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    requested = []
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      credentials: ->(device) { requested << device.host; nil })
    batch = fleet.tftp_backup_all(server: "192.0.2.10", concurrency: 2)
    assert_equal 5, batch.counts.fetch(:missing_credentials)
    assert_equal 1, batch.counts.fetch(:sample_limit)
    assert_equal 5, requested.size
    assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.10", limit_per_vendor: 6) }
  end

  def test_tftp_batch_can_select_all_ready_devices_with_fifty_workers
    rows = (1..6).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    calls = Queue.new
    factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:tftp_backup) do |**options|
          calls << device.host
          Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                          completed_at: Time.now.utc)
        end
        connector.define_singleton_method(:close) {}
      end
    end
    settings = Settings.new(env: { "NC_CONCURRENCY" => "50" })
    assert_equal 50, settings.concurrency
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows), settings: settings,
                      credentials: ->(_) { { username: "admin" } }, connector_factory: factory)
    batch = fleet.tftp_backup_all(server: "192.0.2.10", limit_per_vendor: nil, concurrency: 50)
    assert_equal 6, batch.counts.fetch(:reported_uploaded)
    assert_equal 6, calls.size
  end

  def test_tftp_batch_passes_nxos_vrf_override
    row = { "ip" => "192.0.2.60", "vendor" => "Cisco", "os" => "NX-OS" }
    received = nil
    connector = Object.new
    connector.define_singleton_method(:tftp_backup) do |**options|
      received = options
      Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                      completed_at: Time.now.utc)
    end
    connector.define_singleton_method(:close) {}
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: ->(*) { connector })
    assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.10", vrfs: { cisco_nxos: "bad;vrf" }) }
    assert fleet.tftp_backup_all(server: "192.0.2.10", vrfs: { cisco_nxos: "management" }).success?
    assert_equal "management", received.fetch(:vrf)
  end

  def test_hillstone_inventory_uses_dat_filename_and_passes_vrf_override
    row = { "ip" => "192.0.2.61", "name" => "SZX8-VPN-FW01", "vendor" => "Hillstone Networks" }
    received = nil
    connector = Object.new
    connector.define_singleton_method(:tftp_backup) do |**options|
      received = options
      Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                      completed_at: Time.now.utc)
    end
    connector.define_singleton_method(:close) {}
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: ->(*) { connector })
    assert_raises(ArgumentError) do
      fleet.tftp_backup_all(server: "192.0.2.10", vrfs: { hillstone: "bad;vr" })
    end
    assert fleet.tftp_backup_all(server: "192.0.2.10", vrfs: { hillstone: "mgt-vr" }).success?
    assert_equal "SZX8-VPN-FW01-192.0.2.61.dat", received.fetch(:path)
    assert_equal "mgt-vr", received.fetch(:vrf)
  end

  def test_tftp_batch_uses_vendor_vrfs_and_keeps_upload_when_close_fails
    rows = [{ "ip" => "192.0.2.70", "vendor" => "Cisco", "os" => "NX-OS" },
            { "ip" => "192.0.2.71", "vendor" => "Hillstone Networks" }]
    received = {}
    factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:tftp_backup) do |**options|
          received[device.vendor] = options
          Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                          completed_at: Time.now.utc)
        end
        connector.define_singleton_method(:close) do
          raise IOError, "close failed" if device.vendor == :hillstone
        end
      end
    end
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: factory)
    assert_raises(ArgumentError) do
      fleet.tftp_backup_all(server: "192.0.2.10", vrfs: { h3c: "management" })
    end
    batch = fleet.tftp_backup_all(server: "192.0.2.10",
                                  vrfs: { cisco_nxos: "backup", hillstone: "mgt-vr" })
    assert_equal "backup", received.fetch(:cisco_nxos).fetch(:vrf)
    assert_equal "mgt-vr", received.fetch(:hillstone).fetch(:vrf)
    assert_equal [:reported_uploaded, :reported_with_error], batch.outcomes.map(&:status)
    assert_equal "IOError", batch.outcomes.last.error_type
    refute_nil batch.outcomes.last.backup
  end

  def test_worker_keeps_running_when_result_callback_fails
    rows = (1..2).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    calls = []
    connector_factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:tftp_backup) do |**options|
          calls << device.host
          Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                          completed_at: Time.now.utc)
        end
        connector.define_singleton_method(:close) {}
      end
    end
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: connector_factory)
    batch = fleet.tftp_backup_all(server: "192.0.2.10", concurrency: 1,
                                  on_start: ->(device) { raise IOError, "start log unavailable" if device.host.end_with?(".1") },
                                  on_result: ->(_result) { raise IOError, "result log unavailable" })
    assert_equal 2, calls.size
    assert_equal 2, batch.counts.fetch(:reported_uploaded)
    assert_equal 3, batch.callback_errors.size
    assert(batch.outcomes.all? { |item| item.started_at && item.finished_at && item.duration_ms >= 0 })
    refute batch.success?
  end

  def test_batch_report_defaults_to_private_text_and_accepts_database_store
    rows = [{ "ip" => "192.0.2.80", "vendor" => "unknown" }]
    client = Struct.new(:devices).new(rows)
    Dir.mktmpdir do |directory|
      fleet = Fleet.new(client: client)
      batch = fleet.backup_all(directory: directory)
      assert_equal 1, batch.summary.fetch(:skipped)
      assert_equal 0, batch.summary.fetch(:failed)
      assert_equal [batch.report_location], Dir[File.join(directory, "netdisco-backup-*.json")]
      assert_equal 0o600, File.stat(batch.report_location).mode & 0o777
      assert_equal "unsupported_vendor", JSON.parse(File.read(batch.report_location)).fetch("devices").first.fetch("status")

      repository = Object.new
      repository.define_singleton_method(:create!) do |attributes|
        raise "unexpected total" unless attributes.fetch(:total) == 1

        Struct.new(:id).new(42)
      end
      store = Net::Connector::Netdisco::ResultStore::Database.new(repository: repository)
      database_batch = Fleet.new(client: client, result_store: store).backup_all(directory: directory)
      assert_equal "database:42", database_batch.report_location
      assert_nil database_batch.report_error
    end
  end

  def test_plan_and_execution_share_one_inventory_snapshot
    reads = 0
    client = Object.new
    client.define_singleton_method(:devices) do
      reads += 1
      (1..2).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    end
    fleet = Fleet.new(result_store: nil, client: client, credentials: ->(_) { nil })
    plan = fleet.plan_backup(limit_per_vendor: 1)
    assert_equal ["192.0.2.1"], plan.selected.map(&:host)
    Dir.mktmpdir do |directory|
      batch = fleet.backup_all(directory: directory, plan: plan)
      assert_equal [:missing_credentials, :sample_limit], batch.outcomes.map(&:status)
    end
    assert_equal 1, reads
    assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.10", plan: plan) }
  end

  def test_plan_snapshot_is_immutable_and_invalid_tasks_fail_before_io
    row = { "ip" => "192.0.2.1", "name" => "edge".dup, "vendor" => "H3C" }
    calls = 0
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]),
                      connector_factory: ->(*) { calls += 1 })
    plan = fleet.plan_backup
    row["name"] << "-changed"
    assert_equal "edge", plan.inventory.first.name
    assert_raises(FrozenError) { plan.ready.first[0] = 5 }
    assert_raises(FrozenError) { plan.inventory.first.host << "x" }
    caller_tasks = [[0, plan.inventory.first]]
    copied_plan = Net::Connector::Netdisco::Plan.new(
      mode: :backup, inventory: plan.inventory, ready: caller_tasks, outcomes: [nil]
    )
    caller_tasks.first[0] = 5
    assert_equal 0, copied_plan.ready.first.first
    assert_raises(FrozenError) { copied_plan.ready.first[0] = 5 }

    Dir.mktmpdir do |root|
      directory = File.join(root, "backup")
      invalid_plans = [
        plan.with(ready: [[99, plan.ready.first.last]]),
        plan.with(ready: [plan.ready.first, plan.ready.first]),
        plan.with(outcomes: [Net::Connector::Netdisco::Outcome.new(
          device: plan.inventory.first, status: :sample_limit, backup: nil, error_code: nil, error_type: nil
        )])
      ]
      invalid_plans.each do |invalid|
        assert_raises(ArgumentError) { fleet.backup_all(directory: directory, plan: invalid) }
        refute File.exist?(directory)
      end
    end
    assert_equal 0, calls
  end

  def test_unexpected_backup_value_fails_one_device_without_stopping_batch
    rows = (1..2).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    factory = lambda do |device, _settings|
      Object.new.tap do |connector|
        connector.define_singleton_method(:tftp_backup) do |**settings|
          if device.host.end_with?(".1")
            nil
          else
            Net::Connector::TftpReceipt.new(server: settings.fetch(:host), path: settings.fetch(:path),
                                            completed_at: Time.now.utc)
          end
        end
        connector.define_singleton_method(:close) {}
      end
    end
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: factory)
    batch = fleet.tftp_backup_all(server: "192.0.2.10", concurrency: 1)
    assert_equal [:failed, :reported_uploaded], batch.outcomes.map(&:status)
    assert_equal "TypeError", batch.outcomes.first.error_type
  end

  def test_empty_inventory_is_not_a_successful_batch
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([]))
    Dir.mktmpdir do |directory|
      batch = fleet.backup_all(directory: directory)
      refute batch.success?
      assert_equal :no_devices, batch.summary.fetch(:status)
      assert_equal 0, batch.summary.fetch(:total)

      output = StringIO.new
      error = StringIO.new
      cli = Net::Connector::Netdisco::CLI.new(
        argv: ["--directory", directory], env: {}, output: output, error: error,
        fleet_factory: ->(_) { fleet }
      )
      assert_equal 1, cli.run, error.string
      assert_equal "no_devices", JSON.parse(output.string).fetch("status")
    end
  end

  def test_local_backup_rejects_an_unexpected_result_type
    row = { "ip" => "192.0.2.1", "vendor" => "H3C" }
    connector = Object.new
    connector.define_singleton_method(:backup) do |path:|
      Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: File.basename(path), completed_at: Time.now.utc)
    end
    connector.define_singleton_method(:close) {}
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new([row]),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: ->(*) { connector })
    Dir.mktmpdir do |directory|
      outcome = fleet.backup_all(directory: directory).outcomes.first
      assert_equal :failed, outcome.status
      assert_equal "TypeError", outcome.error_type
      assert_nil outcome.backup
    end
  end

  def test_cli_rejects_host_absent_from_inventory
    rows = [{ "ip" => "192.0.2.1", "vendor" => "H3C" }]
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows))
    Dir.mktmpdir do |directory|
      output = StringIO.new
      error = StringIO.new
      cli = Net::Connector::Netdisco::CLI.new(
        argv: ["--plan", "--host", "192.0.2.2"],
        env: { "NC_BACKUP_DIRECTORY" => directory }, output: output, error: error,
        fleet_factory: ->(_) { fleet }
      )
      assert_equal 2, cli.run
      assert_match(/清单中未找到设备 192\.0\.2\.2/, error.string)
      assert_empty output.string
    end
  end

  def test_cli_help_uses_chinese_descriptions
    output = StringIO.new
    status = Net::Connector::Netdisco::CLI.new(argv: ["--help"], env: {}, output: output, error: StringIO.new).run
    assert_equal 0, status
    assert_includes output.string, "用法：net-backup"
    assert_includes output.string, "预览设备清单，不连接设备"
    assert_includes output.string, "显示帮助"
  end

  def test_report_write_failure_is_visible_without_losing_device_outcomes
    store = Object.new
    store.define_singleton_method(:write) { |*, **| raise IOError, "disk unavailable" }
    row = { "ip" => "192.0.2.90", "vendor" => "unknown" }
    fleet = Fleet.new(client: Struct.new(:devices).new([row]), result_store: store)
    Dir.mktmpdir do |directory|
      batch = fleet.backup_all(directory: directory)
      assert_equal [:unsupported_vendor], batch.outcomes.map(&:status)
      assert_equal "IOError", batch.report_error
      refute batch.success?
    end
  end

  def test_tftp_batch_writes_default_text_report
    row = { "ip" => "192.0.2.91", "vendor" => "H3C" }
    connector = Object.new
    connector.define_singleton_method(:tftp_backup) do |**options|
      Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                      completed_at: Time.now.utc)
    end
    connector.define_singleton_method(:close) {}
    fleet = Fleet.new(client: Struct.new(:devices).new([row]),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: ->(*) { connector })
    Dir.mktmpdir do |directory|
      batch = fleet.tftp_backup_all(server: "192.0.2.10", report_directory: directory)
      assert batch.success?
      assert_equal 1, batch.summary.fetch(:succeeded)
      report = JSON.parse(File.read(batch.report_location))
      assert_equal "tftp", report.fetch("mode")
      assert_equal "reported_uploaded", report.fetch("devices").first.fetch("status")
      assert_equal 0o600, File.stat(batch.report_location).mode & 0o777
    end
  end

  def test_change_notifications_only_fire_for_saved_changes_and_do_not_stop_workers
    rows = (1..2).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } }
    results = []
    changes = []
    factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:backup) do |path:|
          Net::Connector::Backup.new(path: path, bytes: 1, sha256: "new", collected_at: Time.now.utc,
                                     change: device.host.end_with?(".1") ? :changed : :unchanged,
                                     previous_sha256: "old")
        end
        connector.define_singleton_method(:close) {}
      end
    end
    fleet = Fleet.new(result_store: nil, client: Struct.new(:devices).new(rows),
                      credentials: ->(_) { { username: "admin" } }, connector_factory: factory)
    Dir.mktmpdir do |directory|
      batch = fleet.backup_all(directory: directory, concurrency: 1,
                               on_result: ->(item) { results << item.device.host },
                               on_change: ->(item) { changes << item.device.host; raise IOError, "notification failed" })
      assert_equal ["192.0.2.1", "192.0.2.2"], results
      assert_equal ["192.0.2.1"], changes
      assert_equal 2, batch.counts.fetch(:backed_up)
      assert_equal [{ host: "192.0.2.1", error_type: "IOError" }], batch.callback_errors
      refute batch.success?
      assert_equal(["changed", "unchanged"], batch.summary.fetch(:devices).map { |item| item.fetch(:change).to_s })
    end
  end

  def test_yaml_config_loads_non_secret_settings_with_environment_precedence
    Dir.mktmpdir do |directory|
      path = File.join(directory, "config.yml")
      File.write(path, <<~YAML)
        netdisco:
          url: https://inventory.example/netdisco
          page_size: 250
        backup:
          directory: #{directory}/saved
          concurrency: 2
          limit_per_vendor: 3
        inventory:
          include_hosts: [192.0.2.1]
          vendor_overrides:
            Custom Vendor: h3c
        tftp:
          server: 192.0.2.10
          vrfs:
            cisco_nxos: management
      YAML
      env = { "NC_CONCURRENCY" => "4", "NETDISCO_PASSWORD" => "private-password",
              "NC_DEVICE_PASSWORD" => "device-secret" }
      settings = Settings.from_file(path, env: env)
      assert_equal 4, settings.concurrency
      assert_equal File.join(directory, "saved"), settings.backup_directory
      assert_equal :h3c, settings.rules.resolve("vendor" => "Custom Vendor")
      assert_equal ["192.0.2.1"], settings.public_config.fetch(:inventory).fetch(:include_hosts)
      output = StringIO.new
      error = StringIO.new
      status = Net::Connector::Netdisco::CLI.new(argv: ["--config", path, "--show-config"],
                                                 env: env, output: output, error: error).run
      assert_equal 0, status, error.string
      assert_equal 4, JSON.parse(output.string).fetch("backup").fetch("concurrency")
      refute_includes output.string, "private-password"
      refute_includes output.string, "device-secret"

      File.write(path, "netdisco:\n  password: forbidden\n")
      assert_raises(ArgumentError) { Settings.from_file(path, env: {}) }
      File.write(path, "netdisco:\n  url: !ruby/object:Kernel {}\n")
      assert_raises(ArgumentError) { Settings.from_file(path, env: {}) }
    end
  end

  def test_cli_exports_saved_configuration_without_inventory_credentials
    Dir.mktmpdir do |directory|
      source = File.join(directory, "192.0.2.5.txt")
      File.binwrite(source, "hostname edge\nsecret 123\n")
      destination = File.join(directory, "exports", "edge.cfg")
      output = StringIO.new
      error = StringIO.new
      command = Net::Connector::Netdisco::CLI.new(
        argv: ["--directory", directory, "--export", "192.0.2.5", "--output", destination],
        env: {}, output: output, error: error
      )
      assert_equal 0, command.run, error.string
      assert_equal File.binread(source), File.binread(destination)
      assert_equal 0o600, File.stat(destination).mode & 0o777
      assert_equal destination, JSON.parse(output.string).fetch("output")

      stdout = StringIO.new
      assert_equal 0, Net::Connector::Netdisco::CLI.new(
        argv: ["--directory", directory, "--export", "192.0.2.5"], env: {}, output: stdout, error: error
      ).run
      assert_equal File.binread(source), stdout.string
      assert_equal 2, Net::Connector::Netdisco::CLI.new(
        argv: ["--directory", directory, "--export", "192.0.2.0/24"], env: {},
        output: StringIO.new, error: error
      ).run
      File.binwrite(File.join(directory, "renamed-192.0.2.5.txt"), "other")
      assert_equal source, Net::Connector::Storage::SavedConfig.new(directory: directory).find("192.0.2.5")
    end
  end

  def test_cli_plans_one_host_then_runs_a_tftp_batch_from_the_same_inventory
    rows = [{ "ip" => "192.0.2.11", "name" => "edge-a", "vendor" => "H3C" },
            { "ip" => "192.0.2.12", "name" => "edge-b", "vendor" => "H3C" }]
    calls = []
    factory = lambda do |settings|
      connector_factory = lambda do |device, _options|
        Object.new.tap do |connector|
          connector.define_singleton_method(:tftp_backup) do |**options|
            calls << [device.host, options]
            Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: options.fetch(:path),
                                            completed_at: Time.now.utc)
          end
          connector.define_singleton_method(:close) {}
        end
      end
      Fleet.new(settings: settings, client: Struct.new(:devices).new(rows),
                credentials: ->(_) { { username: "backup" } }, connector_factory: connector_factory,
                result_store: nil)
    end
    Dir.mktmpdir do |directory|
      env = { "TFTP_HOST" => "192.0.2.10", "NC_BACKUP_DIRECTORY" => directory }
      output = StringIO.new
      error = StringIO.new
      cli = Net::Connector::Netdisco::CLI.new(
        argv: ["--tftp", "--plan", "--host", "192.0.2.12"], env: env,
        output: output, error: error, fleet_factory: factory
      )
      assert_equal 0, cli.run, error.string
      assert_equal(["192.0.2.12"], JSON.parse(output.string).fetch("selected").map { |item| item.fetch("host") })
      assert_empty calls

      output = StringIO.new
      cli = Net::Connector::Netdisco::CLI.new(
        argv: ["--tftp", "--host", "192.0.2.12"], env: env,
        output: output, error: error, fleet_factory: factory
      )
      assert_equal 1, cli.run, error.string
      assert_equal ["192.0.2.12"], calls.map(&:first)
      assert_equal "192.0.2.10", calls.first.last.fetch(:host)
      assert_equal 1, JSON.parse(output.string).fetch("succeeded")
      assert_equal 1, JSON.parse(output.string).fetch("skipped")
    end
  end
end
