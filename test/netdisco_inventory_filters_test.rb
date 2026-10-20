# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "stringio"
require_relative "../lib/net/connector/netdisco"

class NetdiscoInventoryFiltersTest < Minitest::Test
  N = Net::Connector::Netdisco

  def row(ip: "192.0.2.10", name: "SZX11-Core", vendor: "H3C")
    { "ip" => ip, "name" => name, "vendor" => vendor }
  end

  def test_address_ranges_match_inventory_without_expansion_and_exclusion_wins
    rules = N::Rules.new(include_hosts: ["192.0.2.1-20", "2001:db8::/32"], exclude_hosts: ["192.0.2.10-192.0.2.12"])
    assert N::Device.from_row(row(ip: "192.0.2.1"), rules: rules).ready?
    assert N::Device.from_row(row(ip: "192.0.2.20"), rules: rules).ready?
    assert_equal :filtered, N::Device.from_row(row(ip: "192.0.2.21"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row, rules: rules).issue
    assert N::Device.from_row(row(ip: "2001:db8:ffff:ffff::1"), rules: rules).ready?
    refute N::Device.from_row(row(ip: "2001:db9::1"), rules: rules).ready?
  end

  def test_name_and_vendor_filters_intersect_with_address_filters
    rules = N::Rules.new(include_hosts: ["192.0.2.0/24"], include_names: ["szx11"], exclude_names: ["wlc"],
                         include_vendors: [:h3c], exclude_vendors: [:huawei])
    assert N::Device.from_row(row, rules: rules).ready?
    assert_equal :filtered, N::Device.from_row(row(name: "SZX11-WLC"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(ip: "192.0.3.1"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(name: "SZX12-Core"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(vendor: "Huawei"), rules: rules).issue
    assert_equal :filtered, N::Device.from_row(row(name: nil), rules: rules).issue
  end

  def test_explicit_filter_can_exclude_an_unknown_vendor_without_hiding_selected_unknown_devices
    rules = N::Rules.new(include_names: ["szx11"])
    excluded = N::Device.from_row(row(name: "SZX12-Other", vendor: "Unknown Appliance"), rules: rules)
    selected = N::Device.from_row(row(vendor: "Unknown Appliance"), rules: rules)
    assert_equal :filtered, excluded.issue
    assert_equal :unsupported_vendor, selected.issue
  end

  def test_name_modes_and_dns_fallback_are_literal_and_case_insensitive
    %w[contains prefix glob].each do |mode|
      pattern = mode == "glob" ? "SZX11-*" : "SZX11"
      rules = N::Rules.new(include_names: [pattern], name_match: mode)
      assert N::Device.from_row(row(name: nil).merge("dns" => "szx11-core"), rules: rules).ready?
      refute N::Device.from_row(row(name: "x-szx11-core"), rules: rules).ready? unless mode == "contains"
    end
    rules = N::Rules.new(include_names: ["[CORE]"], name_match: :contains)
    assert N::Device.from_row(row(name: "szx11-[Core]"), rules: rules).ready?
    refute N::Device.from_row(row(name: "szx11-c"), rules: rules).ready?
  end

  def test_invalid_ranges_and_filter_values_are_rejected_without_parser_causes
    ["192.0.2.20-1", "192.0.2.1-256", "192.0.2.1-2001:db8::1", "bad", "2001:db8::/129"].each do |value|
      error = assert_raises(ArgumentError) { N::Rules.new(include_hosts: [value]) }
      assert_nil error.cause
    end
    assert_raises(ArgumentError) { N::Rules.new(name_match: "regex") }
    assert_raises(ArgumentError) { N::Rules.new(include_names: [""]) }
    assert_raises(ArgumentError) { N::Rules.new(exclude_vendors: [:unknown]) }
  end

  def test_blank_yaml_filter_entries_are_rejected_but_explicit_empty_arrays_are_allowed
    %w[include_hosts exclude_hosts include_names exclude_names include_vendors exclude_vendors].each do |field|
      ["   ", "\t", "\n"].each do |blank|
        assert_raises(ArgumentError, field) { N::Config.parse("inventory" => { field => [blank] }) }
      end
      assert_equal "", N::Config.parse("inventory" => { field => [] }).values.first
    end
  end

  def test_formal_cli_rejects_cidr_and_validates_every_repeated_host
    invalid = [["--host", "192.0.2.0/31"], ["--host", "192.0.2.1", "--host", "192.0.2.99"],
               ["--host", "192.0.2.99", "--host", "192.0.2.1"]]
    rows = [row(ip: "192.0.2.0"), row(ip: "192.0.2.1")]
    factory = ->(settings) { N::Fleet.new(settings: settings, inventory: Struct.new(:devices).new(rows)) }
    invalid.each do |arguments|
      status = N::CLI.new(configuration_options: { directories: [] }, argv: [*arguments, "--plan"], env: {}, output: StringIO.new, error: StringIO.new,
                          fleet_factory: factory).run
      assert_equal 2, status, arguments.inspect
    end
    output = StringIO.new
    status = N::CLI.new(configuration_options: { directories: [] }, argv: %w[--host 192.0.2.0 --host 192.0.2.1 --plan], env: {}, output: output,
                        error: StringIO.new, fleet_factory: factory).run
    assert_equal 0, status
    assert_equal(%w[192.0.2.0 192.0.2.1], JSON.parse(output.string).fetch("selected").map { |entry| entry.fetch("host") })
  end

  def test_previews_remove_terminal_controls_but_json_preserves_the_name_as_data
    name = "edge\e]52;c;fixture\a"
    inventory = Struct.new(:devices).new([row(name: name)])
    [:backup, :topology].each do |mode|
      output = StringIO.new
      klass = mode == :backup ? N::CLI::Backup : N::CLI::Topology
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { nil }]) do
        assert_equal 0, klass.new(argv: ["--inventory-only", "--quiet"], env: {}, output: output, error: StringIO.new).run
      end
      refute_match(/[\e\a]/, output.string)
      assert_includes output.string, "edge"
      output = StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { nil }]) do
        assert_equal 0, klass.new(argv: ["--inventory-only", "--quiet", "--json"], env: {}, output: output, error: StringIO.new).run
      end
      refute_includes output.string, "\e"
      assert_includes output.string, "\\u001b"
    end
  end

end
