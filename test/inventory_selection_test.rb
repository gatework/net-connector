# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/inventory/selection"

class InventorySelectionTest < Minitest::Test
  Selection = Net::Connector::Inventory::Selection

  def test_filters_intersect_and_exclusions_win
    selection = Selection.new(include_hosts: ["2001:db8::/32"], include_names: ["CORE"],
                              include_vendors: [:h3c], include_models: ["S68*"], model_match: :glob,
                              exclude_models: ["*spare"])
    device = {host: "2001:db8::1", name: "core-1", vendor: :h3c, model: "s6800"}
    assert selection.evaluate(**device).selected?
    assert_equal [:model_excluded], selection.evaluate(**device.merge(model: "s6800-spare")).reasons
    refute selection.evaluate(**device.merge(model: nil)).selected?
    refute selection.evaluate(**device.merge(vendor: :huawei)).selected?
  end

  def test_rules_are_snapshots_and_ranges_are_shared
    models = [+"S68"]
    selection = Selection.new(include_hosts: ["192.0.2.1-20"], include_models: models)
    models.first.replace("other")
    assert selection.selected?("192.0.2.10", :h3c, model: "s6800")
    refute selection.selected?("192.0.2.21", :h3c, model: "s6800")
    assert selection.frozen?
  end

  def test_invalid_rules_fail_before_selection
    assert_raises(ArgumentError) { Selection.new(include_models: [""]) }
    assert_raises(ArgumentError) { Selection.new(model_match: :regex) }
    assert_raises(ArgumentError) { Selection.new(include_hosts: ["bad"]) }
    assert Selection.new.selected?("192.0.2.1", nil)
  end
end
