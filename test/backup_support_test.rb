# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/net/connector/netdisco"

class BackupSupportTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def test_parser_does_not_mutate_arguments_or_process_state
    args = %w[--concurrency 7 --password private-value]
    before = args.dup
    env = ENV.to_h
    cwd = Dir.pwd
    values = Netdisco::CLI::Options.parse(argv: args)
    assert_equal "7", values[:environment]["NC_CONCURRENCY"]
    assert_equal before, args
    assert_equal env, ENV.to_h
    assert_equal cwd, Dir.pwd
    output = StringIO.new
    assert Netdisco::CLI::Options.parse(argv: ["--help"], output: output)[:help]
    assert_includes output.string, "--concurrency"
    error = assert_raises(ArgumentError) { Netdisco::CLI::Options.parse(argv: ["--unknown=private-value"]) }
    refute_includes error.message, "private-value"
    assert_nil error.cause
  end

  def test_connection_consumes_only_credentials_line_and_returns_resolver_without_network
    settings = Netdisco::Settings.new(env: { "NETDISCO_URL" => "https://inventory.example" })
    input = StringIO.new(JSON.generate(netdisco_username: "reader", netdisco_password: "secret",
                                       device_username: "audit", device_password: "device-secret") + "\nRUN\n")
    client, resolver = Netdisco::Connection.build(settings, stdin_credentials: true, input: input)
    assert_instance_of Netdisco::Client, client
    assert_equal({ username: "audit", password: "device-secret" }, resolver.call(nil))
    assert_equal "RUN\n", input.gets
    ["{secret", "[]", '"secret"'].each do |text|
      error = assert_raises(ArgumentError) do
        Netdisco::Connection.build(settings, stdin_credentials: true, input: StringIO.new(text))
      end
      refute_includes error.message, "secret"
      assert_nil error.cause
    end
  end

  def test_stdin_credentials_use_the_configured_database_client
    settings = Netdisco::Settings.new(env: { "NETDISCO_DB_HOST" => "db.example", "NETDISCO_DB_NAME" => "inventory" },
                                      defaults: { "NETDISCO_SOURCE" => "postgres", "NETDISCO_QUERY" => "SELECT ip FROM device" })
    input = StringIO.new(JSON.generate(netdisco_username: "reader", netdisco_password: "secret",
                                       device_username: "audit", device_password: "device-secret") + "\nRUN\n")
    client, resolver = Netdisco::Connection.build(settings, stdin_credentials: true, input: input)
    assert_instance_of Netdisco::DatabaseClient, client
    assert_equal({ username: "audit", password: "device-secret" }, resolver.call(nil))
    assert_equal "RUN\n", input.gets
  end

end
