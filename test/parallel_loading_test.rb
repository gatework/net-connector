# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"
require_relative "../lib/net/connector/netdisco"

class ParallelLoadingTest < Minitest::Test
  def test_parallel_500_is_supported_at_api_config_and_cli_boundaries
    n = Net::Connector::Netdisco
    assert_equal [2, 4], Net::Connector::Parallel::Pool.new(parallel: 500).map([1, 2]) { |value| value * 2 }
    settings = n::Settings.new(env: {}, defaults: n::Config.parse("backup" => { "parallel" => 500 }, "topology" => { "parallel" => 500 }))
    assert_equal 500, settings.snapshot.parallel
    assert_equal 500, settings.snapshot.topology_options.parallel
    options = n::CLI::Options.parse(argv: %w[--parallel 500])
    assert_equal "500", options.fetch(:environment).fetch("NC_PARALLEL")
    assert_equal 500, Net::Connector::Parallel::Pool.environment_parallel(env: { "NC_PARALLEL" => "500" })
    assert_raises(ArgumentError) { n::CLI::Options.parse(argv: %w[--parallel 501]) }
  end

  def test_old_parallel_options_are_rejected_without_aliases
    assert_raises(ArgumentError) { Net::Connector::Parallel::Pool.new(concurrency: 2) }
    assert_raises(ArgumentError) { Net::Connector::Netdisco::CLI::Options.parse(argv: %w[--concurrency 2]) }
    assert_raises(ArgumentError) { Net::Connector::Netdisco::CLI::Options.parse(argv: %w[-c 2]) }
    assert_raises(ArgumentError) { Net::Connector::Netdisco::Config.parse("backup" => { "concurrency" => 2 }) }
    %w[NC_CONCURRENCY NC_TOPOLOGY_CONCURRENCY].each do |key|
      error = assert_raises(ArgumentError) { Net::Connector::Netdisco::Settings.new(env: { key => "2" }).snapshot }
      assert_includes error.message, key
    end
  end

  def test_parallel_components_load_in_either_order_without_legacy_namespace
    paths = %w[resources parallel/pool parallel/observer]
    [paths, paths.reverse].each do |order|
      script = <<~RUBY
        require "json"
        #{order.map { |name| "require #{"net/connector/#{name}".inspect}" }.join("\n")}
        puts JSON.generate(legacy: Net::Connector.const_defined?(:Concurrency, false),
                           resources: Net::Connector::Resources.prepare!(parallel: 0),
                           result: Net::Connector::Parallel::Pool.new(parallel: 2).map([1, 2]) { |n| n * 2 },
                           observer: Net::Connector::Parallel::Observer.run(task: -> {}, stop: -> {}) { 7 })
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      assert status.success?, error
      result = JSON.parse(output)
      refute result.fetch("legacy")
      assert_nil result.fetch("resources")
      assert_equal [2, 4], result.fetch("result")
      assert_equal 7, result.fetch("observer")
    end
  end
end
