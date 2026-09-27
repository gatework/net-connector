# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "socket"
require "tmpdir"
require "pg"
require_relative "../lib/net/connector/netdisco"

class NetdiscoDatabaseTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  Client = Netdisco::DatabaseClient
  QUERY = "SELECT address AS ip, manufacturer AS vendor FROM inventory WHERE site = $1"

  def connection_options
    { host: "db.example", dbname: "test-database", user: "reader", password: "generated-test-value" }
  end

  def environment
    Client::CONNECTION_ENV.each_with_object({}) do |(key, name), result|
      result[name] = connection_options[key] if connection_options.key?(key)
    end.merge("NETDISCO_SOURCE" => "postgres", "NETDISCO_QUERY" => QUERY,
               "NETDISCO_QUERY_PARAMS" => '["east"]')
  end

  def cli(env, argv = ["--show-config"], &factory)
    output = StringIO.new
    error = StringIO.new
    command = Netdisco::CLI.new(env: env, argv: argv, output: output, error: error,
                                fleet_factory: factory || ->(*) { flunk "must stay offline" })
    [command.run, output.string, error.string]
  end

  def test_postgres_configuration_requires_explicit_query_and_validates_scalar_parameters
    [{ "NETDISCO_SOURCE" => "mysql" }, { "NETDISCO_SOURCE" => "postgres" },
     { "NETDISCO_QUERY_PARAMS" => "{}" }, { "NETDISCO_QUERY_PARAMS" => "[[1]]" },
     { "NETDISCO_QUERY_PARAMS" => "[" }, { "NETDISCO_QUERY" => "SELECT\0secret" }].each do |values|
      env = values.key?("NETDISCO_SOURCE") ? values : environment.merge(values)
      status, output, error = cli(env)
      assert_equal 2, status
      assert_empty output
      refute_empty error
      refute_includes error, "secret"
    end
    options = Client.options(query: QUERY, query_params: ["east", 1, 2.5, true, false, nil])
    assert_equal ["east", 1, 2.5, true, false, nil], options.fetch(:query_params)
    assert_raises(ArgumentError) { Client.options(query: QUERY, query_params: [Float::INFINITY]) }
    assert_raises(ArgumentError) { Client.options(query: QUERY, query_params: ["\0"]) }
    assert_equal 2, cli({ "NETDISCO_QUERY" => QUERY }).first
  end

  def test_settings_select_postgres_and_reuse_policy_while_refreshing_connection_credentials
    env = environment
    settings = Netdisco::Settings.new(env: env).for_run(mode: :inventory)
    env["NETDISCO_QUERY"] = "a later query"
    env["NETDISCO_QUERY_PARAMS"] = '["west"]'
    received = []
    Client.stub(:new, ->(**options) { received << options; Struct.new(:devices).new([]) }) do
      fleet = Netdisco::Fleet.new(settings: settings, result_store: nil)
      2.times do |index|
        env["NETDISCO_DB_PASS"] = "rotation-#{index}"
        assert_empty fleet.devices
      end
    end
    assert_equal([QUERY, QUERY], received.map { |value| value.fetch(:query) })
    assert_equal([["east"], ["east"]], received.map { |value| value.fetch(:query_params) })
    assert_equal(%w[rotation-0 rotation-1], received.map { |value| value.fetch(:connection_options).fetch(:password) })
  end

  def test_connection_information_never_enters_policy_or_configuration_output
    env = environment
    settings = Netdisco::Settings.new(env: env)
    policy = settings.snapshot(mode: :inventory)
    status, output, error = cli(env)
    assert_equal 0, status, error
    assert_equal "postgres", JSON.parse(output).fetch("netdisco").fetch("source")
    [Marshal.dump(policy), output, settings.inspect, settings.client.inspect].each do |text|
      connection_options.each_value { |value| refute_includes text, value }
    end
    assert_raises(ArgumentError) { Netdisco::Settings.new(env: env.except("NETDISCO_DB_PASS")).client }
    # defaults/overrides 不能作为连接凭据后门。
    assert_raises(ArgumentError) { Netdisco::Settings.new(env: env.except("NETDISCO_DB_PASS"), defaults: env).client }
  end

  def test_query_options_are_copied_before_the_caller_can_change_them
    query = +QUERY
    params = [+"east"]
    client = Client.new(connection_options: connection_options, query: query, query_params: params)
    query.replace("another query")
    params.first.replace("west")
    options = client.instance_variable_get(:@options)
    assert_equal QUERY, options.fetch(:query)
    assert_equal ["east"], options.fetch(:query_params)
    assert_predicate options.fetch(:query), :frozen?
    assert_predicate options.fetch(:query_params).first, :frozen?
  end

  def test_yaml_env_and_cli_precedence_and_queries_are_available_to_the_existing_plan_flow
    Dir.mktmpdir do |directory|
      path = File.join(directory, "settings.yml")
      File.write(path, <<~YAML)
        netdisco:
          source: postgres
          query: #{QUERY}
          query_params: [yaml]
          page_size: 2
      YAML
      env = { "NETDISCO_QUERY" => "SELECT env AS ip", "NETDISCO_QUERY_PARAMS" => '["env"]' }
      status, output, error = cli(env, ["--config", path, "--show-config", "--query", "SELECT cli AS ip",
                                        "--query-params", '["cli"]'])
      assert_equal 0, status, error
      config = JSON.parse(output).fetch("netdisco")
      assert_equal "SELECT cli AS ip", config.fetch("query")
      assert_equal ["cli"], config.fetch("query_params")
      assert_equal 2, config.fetch("page_size")

      status, output, error = cli(environment, ["--plan", "--query", QUERY]) do |settings|
        assert_equal :postgres, settings.inventory_source
        Netdisco::Fleet.new(settings: settings,
                            client: Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }]),
                            credentials: ->(*) { flunk "plan must not request device credentials" })
      end
      assert_equal 0, status, error
      assert_equal "192.0.2.1", JSON.parse(output).fetch("selected").first.fetch("host")

      %w[password user db_pass db_user db_host].each do |name|
        File.write(path, "netdisco:\n  #{name}: forbidden\n")
        assert_raises(ArgumentError) { Netdisco::ConfigFile.load(path) }
      end
    end
  end

  def test_postgres_connection_options_reject_invalid_values_without_echoing_secrets
    [{ password: "\0sensitive" }, { port: "secret" }, { port: 65_536 }, { connect_timeout: 0 },
     { sslmode: "unknown" }, { dbname: "postgres://reader:secret@db/inventory" },
     { dbname: "dbname=inventory password=secret" }, { options: "secret" }].each do |values|
      error = assert_raises(ArgumentError) do
        Client.new(connection_options: connection_options.merge(values), query: QUERY)
      end
      refute_includes error.message, "secret"
      refute_includes error.message, "sensitive"
    end
  end

  def test_connection_failures_are_sanitized_and_do_not_touch_devices_or_files
    client = Client.new(connection_options: connection_options, query: QUERY)
    fleet = Netdisco::Fleet.new(client: client, settings: Netdisco::Settings.new(env: {}), result_store: nil,
                                credentials: ->(*) { flunk "must not read device credentials" })
    PG::Connection.stub(:connect_start, ->(*) { raise PG::ConnectionBad, "generated-test-value in server response" }) do
      Dir.mktmpdir do |directory|
        destination = File.join(directory, "backup")
        error = assert_raises(Netdisco::Client::Error) { fleet.backup_all(directory: destination) }
        assert_equal :connection_failed, error.code
        assert_nil error.cause
        refute_includes error.full_message, "generated-test-value"
        refute_path_exists destination
      end
    end
  end

  def test_export_and_help_remain_offline_with_incomplete_database_configuration
    env = { "NETDISCO_SOURCE" => "postgres", "NETDISCO_DB_PASS" => "secret" }
    assert_equal 0, cli(env, ["--help"]).first
    assert_equal 0, cli(env, ["--version"]).first
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "192.0.2.1.txt"), "fixture")
      status, output, error = cli(env, ["--export", "192.0.2.1", "--directory", directory])
      assert_equal 0, status, error
      assert_equal "fixture", output
    end
    assert_equal 2, cli(env, ["--export", "192.0.2.1", "--query", QUERY]).first
  end

  class QueryResult
    attr_reader :fields, :cleared

    def initialize(rows = [], fields: rows.first&.keys || ["ip"], error: nil)
      @rows, @fields, @error = rows, fields, error
    end

    def check
      raise @error if @error
    end

    def ntuples = @rows.size
    def each(&block) = @rows.each(&block)
    def clear = @cleared = true
  end

  # 模拟 pg 的结果分片，控制错误和时钟，不用固定 sleep 猜测到达顺序。
  class Connection
    attr_reader :commands, :closed, :results, :single_row_calls
    attr_accessor :before_result

    def initialize(pages)
      @pages = pages
      @commands = []
      @results = []
      @single_row_calls = 0
    end

    def set_notice_processor(&block) = block.call("sensitive-notice")
    def connect_poll = PG::PGRES_POLLING_OK
    def setnonblocking(_value); end
    def set_client_encoding(_value); end

    def exec(sql)
      @commands << [sql]
      QueryResult.new.tap { |result| @results << result }
    end

    def exec_params(sql, params)
      @commands << [sql, params]
      QueryResult.new.tap { |result| @results << result }
    end

    def send_query_params(sql, params)
      @commands << [sql, params]
      @pending = @pages.shift || [QueryResult.new]
      @results.concat(@pending)
    end

    def set_single_row_mode = @single_row_calls += 1

    def get_result
      @before_result&.call
      @pending.shift
    end

    def finish = @closed = true
  end

  def streaming_client(connection, **options)
    value = Client.new(connection_options: connection_options, query: QUERY, query_params: ["east"], **options)
    PG::Connection.stub(:connect_start, ->(received) { assert_equal connection_options, received; connection }) { yield value }
  end

  def test_streamed_rows_share_a_read_only_cursor_and_close_all_results_and_connection
    first = QueryResult.new([{ "ip" => "192.0.2.1", "vendor" => "H3C", "ignored" => "private" }])
    last = QueryResult.new([{ "ip" => "2001:db8::1", "vendor" => nil }])
    connection = Connection.new([[first, QueryResult.new], [last, QueryResult.new], [QueryResult.new]])
    streaming_client(connection, page_size: 1) do |client|
      rows = client.devices
      assert_equal [{ "ip" => "192.0.2.1", "vendor" => "H3C" }, { "ip" => "2001:db8::1", "vendor" => nil }], rows
    end
    assert_equal ["BEGIN READ ONLY"], connection.commands.first
    declaration = connection.commands.find { |command| command.first.start_with?("DECLARE ") }
    assert_includes declaration.first, QUERY
    assert_equal ["east"], declaration.last
    assert_equal ["ROLLBACK"], connection.commands.last
    assert_equal 3, connection.single_row_calls
    assert_predicate connection, :closed
    assert(connection.results.all?(&:cleared))
  end

  def test_streaming_budgets_count_discarded_columns_and_duplicates_before_return
    row = { "ip" => "192.0.2.1", "private" => "sensitive-marker" }
    scenarios = [[:max_response_bytes, { max_response_bytes: 10 }],
                 [:max_inventory_bytes, { max_inventory_bytes: 10 }],
                 [:max_devices, { max_devices: 1 }],
                 [:max_pages, { page_size: 1, max_pages: 1 }]]
    scenarios.each do |code, options|
      connection = Connection.new([[QueryResult.new([row]), QueryResult.new([row]), QueryResult.new]])
      streaming_client(connection, **options) do |client|
        error = assert_raises(Netdisco::Client::Error) { client.devices }
        assert_equal code, error.code
        assert_nil error.cause
        refute_includes error.full_message, "sensitive-marker"
      end
      assert_predicate connection, :closed
      refute_includes connection.commands, ["ROLLBACK"]
    end
  end

  def test_invalid_empty_schema_and_late_null_addresses_never_return_partial_results
    invalid = [QueryResult.new([], fields: ["name"]), QueryResult.new([], fields: %w[ip ip]),
               QueryResult.new([{ "ip" => nil }]), QueryResult.new([{ "ip" => " " }])]
    invalid.each do |result|
      connection = Connection.new([[QueryResult.new([{ "ip" => "192.0.2.1" }]), result]])
      streaming_client(connection) do |client|
        error = assert_raises(Netdisco::Client::Error) { client.devices }
        assert_equal :invalid_inventory, error.code
      end
      assert_predicate result, :cleared
      assert_predicate connection, :closed
    end
  end

  def test_late_query_errors_and_cancellation_close_the_connection_and_remove_cause
    [PG::Error.new("sensitive-marker"), PG::QueryCanceled.new("sensitive-marker")].each do |exception|
      result = QueryResult.new(error: exception)
      connection = Connection.new([[QueryResult.new([{ "ip" => "192.0.2.1" }]), result]])
      streaming_client(connection) do |client|
        error = assert_raises(Netdisco::Client::Error) { client.devices }
        assert_equal(exception.is_a?(PG::QueryCanceled) ? :inventory_timeout : :query_failed, error.code)
        assert_nil error.cause
        refute_includes error.full_message, "sensitive-marker"
      end
      assert_predicate result, :cleared
      assert_predicate connection, :closed
    end
  end

  def test_total_deadline_does_not_restart_between_fetches
    clock = 0
    connection = Connection.new([[QueryResult.new([{ "ip" => "192.0.2.1" }]), QueryResult.new]])
    connection.before_result = -> { clock = 11 if connection.single_row_calls > 1 }
    streaming_client(connection, page_size: 1, inventory_timeout: 10) do |client|
      client.stub(:monotonic, -> { clock }) do
        error = assert_raises(Netdisco::Client::InventoryTimeout) { client.devices }
        assert_equal :inventory_timeout, error.code
      end
    end
    assert_equal 2, connection.single_row_calls
    assert_predicate connection, :closed
  end

  def test_interrupt_also_closes_the_owned_connection
    connection = Connection.new([])
    connection.before_result = -> { raise Interrupt }
    streaming_client(connection) { |client| assert_raises(Interrupt) { client.devices } }
    assert_predicate connection, :closed
  end

  def test_total_timeout_closes_socket_even_during_authentication_without_garbage_collection
    server = TCPServer.new("127.0.0.1", 0)
    accepted = Queue.new
    worker = Thread.new { accepted << server.accept }
    options = connection_options.merge(host: "127.0.0.1", port: server.addr[1], sslmode: "disable")
    client = Client.new(connection_options: options, query: QUERY, inventory_timeout: 0.1)
    was_disabled = GC.disable
    error = assert_raises(Netdisco::Client::InventoryTimeout) { client.devices }
    assert_equal :inventory_timeout, error.code
    peer = accepted.pop
    # 读取已发送的启动包直到 EOF；有限等待仅作为失败上限，不以固定 sleep 判定关闭。
    loop do
      assert peer.wait_readable(1), "authentication socket remained open"
      break unless peer.read_nonblock(4096, exception: false)
    end
  ensure
    GC.enable unless was_disabled
    peer&.close
    server&.close
    worker&.join
  end
end
