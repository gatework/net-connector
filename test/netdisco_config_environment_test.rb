# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco/config"

class NetdiscoConfigEnvironmentTest < Minitest::Test
  Config = Net::Connector::Netdisco::Config

  def test_projects_only_requested_sections_and_decodes_numeric_boolean_and_string_fields
    environment = { "ND_PAGE_SIZE" => "12", "ND_CACHE_TTL" => "2.5", "ND_CACHE_ENABLED" => "false",
                    "ND_ALLOW_INSECURE_HTTP" => "true", "ND_URL" => "https://inventory.example.test",
                    "NC_TOPOLOGY_LIMIT" => "4", "NC_MAX_SCRIPT_OUTPUT_BYTES" => "8192",
                    "NC_PARALLEL" => "not-selected" }
    assert_equal({ "netdisco" => { "page_size" => 12, "cache_ttl" => 2.5, "cache_enabled" => false,
                                  "allow_insecure_http" => true, "url" => "https://inventory.example.test" },
                   "topology" => { "limit" => 4 }, "ssh" => { "max_script_output_bytes" => 8192 } },
                 Config.from_environment(environment, sections: %w[netdisco topology ssh]))
  end

  def test_decodes_lists_and_json_hashes_and_arrays_without_losing_false_or_nil_members
    environment = { "NC_INCLUDE_HOSTS" => "192.0.2.1, 192.0.2.2", "NC_EXCLUDE_HOSTS" => "",
                    "NC_VENDOR_OVERRIDES" => '{"edge":"H3C"}',
                    "NC_DEVICE_RULES" => '[{"match":"edge","enabled":false}]',
                    "ND_QUERY_PARAMS" => '["edge",null,false,12]' }
    assert_equal({ "inventory" => { "include_hosts" => ["192.0.2.1", "192.0.2.2"], "exclude_hosts" => [],
                                   "vendor_overrides" => { "edge" => "H3C" },
                                   "device_rules" => [{ "match" => "edge", "enabled" => false }] },
                   "netdisco" => { "query_params" => ["edge", nil, false, 12] } },
                 Config.from_environment(environment, sections: %w[inventory netdisco]))
  end

  def test_higher_fields_mask_invalid_lower_values_before_decoding_without_mutation
    environment = { "ND_PAGE_SIZE" => "private-invalid-integer", "ND_CACHE_ENABLED" => "private-invalid-boolean",
                    "NC_INCLUDE_HOSTS" => "private-empty,,list", "NC_DEVICE_RULES" => "private-invalid-json",
                    "ND_MAX_DEVICES" => "3" }.freeze
    higher = { "netdisco" => { "page_size" => nil, "cache_enabled" => false },
               "inventory" => { "include_hosts" => [], "device_rules" => [] } }.freeze
    result = Config.from_environment(environment, sections: %w[netdisco inventory], higher: higher)
    assert_equal({ "netdisco" => { "max_devices" => 3 } }, result)
    assert_nil higher["netdisco"]["page_size"]
    assert_equal false, higher["netdisco"]["cache_enabled"]
    assert_equal "private-invalid-integer", environment["ND_PAGE_SIZE"]
  end

  def test_unknown_and_sensitive_environment_fields_are_never_projected
    environment = { "ND_PASSWORD" => "private-secret", "ND_DB_PASSWORD" => "private-secret",
                    "ND_API_KEY" => "private-secret", "NC_DEVICE_PASSWORD" => "private-secret",
                    "NC_DEVICE_USERNAME" => "private-secret", "UNRELATED_SECRET" => "private-secret",
                    "ND_UNKNOWN" => "private-secret", "NC_CONFIG" => "private-secret",
                    "ND_PAGE_SIZE" => "5" }
    result = Config.from_environment(environment, sections: Config::FIELDS.keys)
    assert_equal({ "netdisco" => { "page_size" => 5 } }, result)
    refute_includes result.inspect, "private-secret"
  end

  def test_conversion_errors_report_only_public_keys_without_values_or_causes
    { "ND_PAGE_SIZE" => "private-number", "ND_CACHE_TTL" => "private-number",
      "ND_CACHE_ENABLED" => "private-boolean", "NC_DEVICE_RULES" => "private-json",
      "ND_QUERY_PARAMS" => "private-json" }.each do |key, value|
      error = assert_raises(ArgumentError) { Config.from_environment({ key => value }, sections: Config::FIELDS.keys) }
      assert_includes error.message, key
      refute_includes error.message, value
      assert_nil error.cause
    end
  end

  def test_schema_validation_rejects_invalid_ranges_lists_and_json_shapes_without_values
    { "ND_PAGE_SIZE" => "0", "ND_CACHE_TTL" => "-1", "ND_URL" => " ",
      "NC_INCLUDE_HOSTS" => "private-value,,edge", "NC_DEVICE_RULES" => '{"private-value":1}',
      "NC_VENDOR_OVERRIDES" => '["private-value"]', "ND_QUERY_PARAMS" => '{"private-value":1}' }.each do |key, value|
      error = assert_raises(ArgumentError) { Config.from_environment({ key => value }, sections: Config::FIELDS.keys) }
      refute_includes error.message, "private-value"
      assert_nil error.cause
    end
  end

  def test_non_string_environment_values_are_rejected_without_inspecting_contents
    [nil, ["private-value"], { "private-value" => 1 }].each do |value|
      error = assert_raises(ArgumentError) do
        Config.from_environment({ "NC_INCLUDE_HOSTS" => value }, sections: %w[inventory])
      end
      assert_includes error.message, "NC_INCLUDE_HOSTS"
      refute_includes error.message, "private-value"
      assert_nil error.cause
    end
  end

  def test_selected_sections_validate_inventory_without_interpreting_unrelated_policies
    document = { "netdisco" => { "page_size" => 5 }, "inventory" => { "include_hosts" => [] },
                 "backup" => { "parallel" => "unused-invalid" }, "ssh" => "unused-invalid" }
    assert_equal({ "ND_PAGE_SIZE" => "5", "NC_INCLUDE_HOSTS" => "" },
                 Config.parse_sections(document, sections: %w[netdisco inventory]))
    assert_raises(ArgumentError) { Config.parse(document) }
    assert_raises(ArgumentError) { Config.parse_sections(document.merge("netdisco" => { "page_size" => 0 }), sections: %w[netdisco inventory]) }
    assert_raises(ArgumentError) { Config.parse_sections(document.merge("netdsico" => {}), sections: %w[netdisco inventory]) }
  end
end
