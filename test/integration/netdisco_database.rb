# frozen_string_literal: true

# 显式运行 bundle exec rake test:postgres；只使用测试自己创建的临时数据库。
require "minitest/autorun"
require "fileutils"
require "open3"
require "securerandom"
require "stringio"
require "tmpdir"
require "pg"
require_relative "../../lib/net/connector/netdisco"

class NetdiscoDatabaseIntegrationTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  QUERY = "SELECT host(ip) AS ip, name, vendor, os FROM device ORDER BY ip"

  class << self
    attr_reader :options

    def start_database
      @bindir = ENV["NC_TEST_PG_BINDIR"]
      unless @bindir
        output, status = Open3.capture2("pg_config", "--bindir")
        raise "pg_config failed; install PostgreSQL server tools" unless status.success?

        @bindir = output.strip
      end
      @directory = Dir.mktmpdir("nc-pg-", "/tmp")
      @data = File.join(@directory, "data")
      password = SecureRandom.hex(16)
      password_path = File.join(@directory, "password")
      File.write(password_path, password, perm: 0o600)
      command("initdb", "-D", @data, "-U", "inventory_test", "--auth=scram-sha-256",
              "--pwfile", password_path, "--encoding=UTF8", "--no-locale")
      File.delete(password_path)
      # 只监听本次私有目录中的 Unix socket，不绑定 TCP，也不接触已有 PostgreSQL 服务。
      File.open(File.join(@data, "postgresql.conf"), "a") do |file|
        file.puts "listen_addresses = ''"
        file.puts "unix_socket_directories = '#{@directory}'"
      end
      command("pg_ctl", "-D", @data, "-l", File.join(@directory, "server.log"), "-w", "start")
      @options = { host: @directory, dbname: "postgres", user: "inventory_test", password: password }.freeze
      PG.connect(@options) do |connection|
        connection.exec("CREATE TABLE device (ip inet, name text, vendor text, os text)")
        connection.exec_params("INSERT INTO device VALUES ($1, $2, $3, $4), ($5, $6, $7, $8)",
                               ["192.0.2.1", "core", "H3C", "comware", "2001:db8::1", "edge", "Cisco", "ios"])
      end
    rescue StandardError
      stop_database
      raise
    end

    def stop_database
      return unless @directory

      if File.exist?(File.join(@data, "postmaster.pid"))
        command("pg_ctl", "-D", @data, "-m", "immediate", "-w", "stop")
      end
      FileUtils.remove_entry(@directory)
      @directory = nil
    end

    def command(name, *arguments)
      _output, _error, status = Open3.capture3(File.join(@bindir, name), *arguments)
      raise "temporary PostgreSQL #{name} failed (#{status.exitstatus})" unless status.success?
    end
  end

  def client(query: QUERY, **options)
    Netdisco::DatabaseClient.new(connection_options: self.class.options, query: query, **options)
  end

  def environment
    Netdisco::DatabaseClient::CONNECTION_ENV.each_with_object({}) do |(key, name), env|
      env[name] = self.class.options[key] if self.class.options.key?(key)
    end
  end

  def assert_no_connection_leak
    PG.connect(self.class.options) do |connection|
      # 关闭 socket 与服务端退出之间有异步间隙；仅检查客户端会话，排除后台 worker。
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      remaining = nil
      loop do
        remaining = connection.exec(<<~SQL).getvalue(0, 0)
          SELECT count(*) FROM pg_stat_activity
          WHERE usename = current_user AND pid <> pg_backend_pid() AND backend_type = 'client backend'
        SQL
        break if remaining == "0" || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        connection.exec("SELECT pg_sleep(0.01)").clear
      end
      assert_equal "0", remaining, "database connection leaked"
    end
  end

  def assert_failure(query: QUERY, code: :query_failed, **options)
    error = assert_raises(Netdisco::Client::Error) { client(query: query, **options).devices }
    assert_equal code, error.code
    assert_nil error.cause
    refute_includes error.full_message, "sensitive-marker"
    refute_includes error.full_message, self.class.options.fetch(:password)
    assert_no_connection_leak
    error
  end

  def test_query_fills_existing_inventory_and_preserves_ipv6
    rows = client(page_size: 1).devices
    assert_equal(["192.0.2.1", "2001:db8::1"], rows.map { |row| row.fetch("ip") })
    fleet = Netdisco::Fleet.new(client: client, settings: Netdisco::Settings.new(env: {}), result_store: nil)
    assert_equal %i[h3c cisco_ios], fleet.plan_backup.selected.map(&:vendor)
    assert_no_connection_leak
  end

  def test_cte_joins_aliases_and_parameter_values_are_not_interpolated
    query = <<~SQL
      WITH chosen AS (SELECT * FROM device WHERE vendor = $1)
      SELECT host(d.ip) AS ip, d.vendor, $2::text AS name
      FROM chosen d JOIN device other ON other.ip = d.ip ORDER BY d.ip;
    SQL
    value = "quote'; DROP TABLE device; --"
    rows = client(query: query, query_params: ["H3C", value]).devices
    assert_equal 1, rows.length
    assert_equal value, rows.first.fetch("name")
    assert_equal 2, client.devices.length
    assert_empty client(query: QUERY.sub("ORDER BY ip", "WHERE vendor = $1"), query_params: [value]).devices
  end

  def test_transaction_is_read_only_and_extra_columns_are_dropped
    query = "SELECT host(ip) AS ip, current_setting('transaction_read_only') AS name, 'sensitive-marker' AS snmp_comm FROM device"
    rows = client(query: query).devices
    assert_equal ["on"], rows.map { |row| row.fetch("name") }.uniq
    assert(rows.all? { |row| row.keys.sort == %w[ip name] })
    assert_failure(query: "DELETE FROM device RETURNING host(ip) AS ip")
    assert_failure(query: "WITH deleted AS (DELETE FROM device RETURNING ip) SELECT host(ip) AS ip FROM deleted")
    assert_failure(query: "SELECT host(ip) AS ip FROM device FOR UPDATE")
    assert_equal 2, client.devices.size
  end

  def test_multiple_statements_cannot_end_read_only_transaction
    assert_failure(query: "SELECT host(ip) AS ip FROM device; COMMIT; DELETE FROM device;")
    assert_equal 2, client.devices.size
  end

  def test_empty_result_still_validates_column_names_and_null_ip_is_invalid
    assert_empty client(query: "SELECT host(ip) AS ip FROM device WHERE false").devices
    assert_failure(query: "SELECT name FROM device WHERE false", code: :invalid_inventory)
    assert_failure(query: "SELECT ip, ip FROM device", code: :invalid_inventory)
    assert_failure(query: "SELECT NULL::text AS ip", code: :invalid_inventory)
    assert_failure(query: "SELECT ' '::text AS ip", code: :invalid_inventory)
  end

  def test_duplicate_addresses_remain_visible_to_fleet_and_consume_budget
    query = "SELECT '192.0.2.1' AS ip, 'H3C' AS vendor FROM generate_series(1, 3)"
    fleet = Netdisco::Fleet.new(client: client(query: query), settings: Netdisco::Settings.new(env: {}), result_store: nil)
    assert_equal [:duplicate_host] * 3, fleet.devices.map(&:issue)
    assert_failure(query: query, max_devices: 2, code: :max_devices)
  end

  def test_page_and_inventory_budgets_are_shared_across_fetches
    assert_failure(page_size: 1, max_pages: 1, code: :max_pages)
    assert_failure(max_devices: 1, code: :max_devices)
    assert_failure(query: "SELECT '192.0.2.1' AS ip, repeat('x', 1024) AS ignored", max_response_bytes: 128,
                    code: :max_response_bytes)
    query = "SELECT '192.0.2.1' AS ip FROM generate_series(1, 3)"
    assert_failure(query: query, page_size: 1, max_response_bytes: 32, max_inventory_bytes: 24,
                    code: :max_inventory_bytes)
  end

  def test_sql_errors_after_received_rows_discard_the_whole_inventory
    query = "SELECT CASE WHEN n < 3 THEN '192.0.2.1' ELSE (n / (n - 3))::text END AS ip FROM generate_series(1, 3) n"
    fleet = Netdisco::Fleet.new(client: client(query: query, page_size: 1), settings: Netdisco::Settings.new(env: {}),
                                credentials: ->(*) { flunk "incomplete inventory must not reach devices" })
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "backup")
      assert_raises(Netdisco::Client::Error) { fleet.backup_all(directory: destination) }
      refute_path_exists destination
    end
    assert_no_connection_leak
  end

  def test_query_errors_and_authentication_errors_do_not_echo_server_messages
    assert_failure(query: "SELECT sensitive_marker AS ip /* sensitive-marker */ FROM device")
    options = self.class.options.merge(password: "sensitive-marker")
    value = Netdisco::DatabaseClient.new(connection_options: options, query: QUERY)
    error = assert_raises(Netdisco::Client::Error) { value.devices }
    assert_equal :connection_failed, error.code
    assert_nil error.cause
    refute_includes error.full_message, "sensitive-marker"
  end

  def test_query_timeout_closes_connection_without_partial_inventory
    assert_failure(query: "SELECT '192.0.2.1' AS ip FROM pg_sleep(5)", inventory_timeout: 0.1,
                    code: :inventory_timeout)
  end

  def test_cli_plan_uses_live_query_without_http_or_device_credentials
    output = StringIO.new
    error = StringIO.new
    status = Netdisco::CLI.new(env: environment, argv: ["--plan", "--source", "postgres", "--query", QUERY], output: output, error: error).run
    assert_equal 0, status, error.string
    assert_equal(["192.0.2.1", "2001:db8::1"], JSON.parse(output.string).fetch("selected").map { |row| row.fetch("host") })
    assert_empty error.string
    assert_no_connection_leak
  end
end

NetdiscoDatabaseIntegrationTest.start_database
Minitest.after_run { NetdiscoDatabaseIntegrationTest.stop_database }
