# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"

class TopologyOptionsTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_reference_topology_fields_are_validated_and_resolved_by_settings
    values = N::ConfigFile.parse("topology" => { "mode" => "plan", "cache_mode" => "only", "concurrency" => 8,
                                                 "directory" => "./topology_reports", "description_format" => "To_%{neighbor}_%{port}",
                                                 "abbreviate_ports" => true, "lowercase_ports" => false })
    options = N::Settings.new(env: {}, defaults: values).snapshot(mode: :topology).topology_options
    assert_equal :plan, options.mode
    assert_equal :only, options.cache_mode
    assert_equal 8, options.concurrency
    assert_equal File.expand_path("topology_reports"), options.directory
    assert_equal "To_Edge_Gi1/0/1", options.format(neighbor: "Edge", port: "Gi1/0/1")
    assert options.abbreviate_ports
    refute options.lowercase_ports
    assert options.frozen?
  end

  def test_invalid_description_placeholders_and_capacities_fail_before_inventory
    [{ "description_format" => "To_%{password}" }, { "description_format" => "%s" },
     { "description_format" => "To_%{neighbor}\nshutdown" }, { "concurrency" => 51 }, { "cache_mode" => "unknown" },
     { "limit" => 0 }, { "mode" => "unknown" }].each do |values|
      assert_raises(ArgumentError) do
        settings = N::Settings.new(env: {}, defaults: N::ConfigFile.parse("topology" => values))
        settings.snapshot(mode: :topology)
      end
    end
  end
end
