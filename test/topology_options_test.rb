# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco"

class TopologyOptionsTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_reference_topology_fields_are_validated_and_resolved_by_settings
    values = N::Config.parse("topology" => { "mode" => "plan", "cache_mode" => "only", "parallel" => 8,
                                                 "directory" => "./topologys", "description_format" => "To_%{neighbor}_%{port}",
                                                 "abbreviate_ports" => true, "lowercase_ports" => false })
    options = N::Settings.new(env: {}, defaults: values).snapshot(mode: :topology).topology_options
    assert_equal :plan, options.mode
    assert_equal :only, options.cache_mode
    assert_equal 8, options.parallel
    assert_equal File.expand_path("topologys"), options.directory
    assert_equal "To_Edge_Gi1/0/1", options.format(neighbor: "Edge", port: "Gi1/0/1")
    assert options.abbreviate_ports
    refute options.lowercase_ports
    assert options.frozen?
  end

  def test_invalid_description_placeholders_and_capacities_fail_before_inventory
    [{ "description_format" => "To_%{password}" }, { "description_format" => "%s" },
     { "description_format" => "To_%{neighbor}\nshutdown" }, { "parallel" => 501 }, { "cache_mode" => "unknown" },
     { "limit" => 0 }, { "mode" => "unknown" }].each do |values|
      assert_raises(ArgumentError) do
        settings = N::Settings.new(env: {}, defaults: N::Config.parse("topology" => values))
        settings.snapshot(mode: :topology)
      end
    end
  end

  def test_updated_options_revalidate_and_own_their_format
    original = N::Topology::Options.new
    assert_same original, original.with
    assert_raises(ArgumentError) { original.with(parallel: 0) }
    assert_raises(ArgumentError) { original.with(description_format: "%{password}") }
    format = +"Peer_%{neighbor}"
    updated = original.with(description_format: format)
    format.replace("changed")
    assert_equal "Peer_Edge", updated.format(neighbor: "Edge", port: "Gi1")
    assert updated.description_format.frozen?
  end

  def test_name_prefixes_are_explicit_and_do_not_hide_real_neighbor_changes
    options = N::Settings.new(env: {}, defaults: N::Config.parse("topology" => { "neighbor_name_prefixes" => ["AP-"] })).topology_options
    neighbor = Net::Connector::Interfaces::Neighbor.new(local_interface: "GE1/0/1", neighbor_name: "room_01",
                                                      neighbor_interface: "Smartrate-Ethernet1/0/1", chassis_id: "chassis", protocol: :lldp)
    assert options.description_matches?("TO_AP-room_01_SE1/0/1", "To_room_01_SE1/0/1", neighbor)
    refute N::Topology::Options.new.description_matches?("TO_AP-room_01_SE1/0/1", "To_room_01_SE1/0/1", neighbor)
    refute options.description_matches?("TO_AP-room_02_SE1/0/1", "To_room_01_SE1/0/1", neighbor)
    refute options.description_matches?("TO_AP-room_01_SE1/0/2", "To_room_01_SE1/0/1", neighbor)
    prefixes = [+"AP-"]
    fixed = N::Topology::Options.new(neighbor_name_prefixes: prefixes)
    prefixes.first.replace("SW-")
    assert_equal ["AP-"], fixed.neighbor_name_prefixes
    assert fixed.neighbor_name_prefixes.frozen?
    assert_raises(ArgumentError) { fixed.with(neighbor_name_prefixes: [""]) }
  end

end
