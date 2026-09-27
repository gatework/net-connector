# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"

class ModuleLoadingTest < Minitest::Test
  LIBRARY = File.expand_path("../lib", __dir__)
  VENDORS = { "h3c" => "H3c", "h3c_wireless" => "H3cWireless", "cisco_ios" => "CiscoIos",
              "cisco_nxos" => "CiscoNxos", "huawei" => "Huawei", "hillstone" => "Hillstone",
              "palo_alto" => "PaloAlto", "radware" => "Radware" }.freeze

  def test_legacy_engine_entry_points_share_the_public_device_classes
    require_relative "../lib/net/connector"
    base = Net::Connector::Base
    profile = Net::Connector::Profile
    require_relative "../lib/net/connector/engine/base"
    require_relative "../lib/net/connector/engine/profile"
    require_relative "../lib/net/connector/engine"
    assert_same base, Net::Connector::Base
    assert_same profile, Net::Connector::Profile
  end

  def test_engine_core_has_no_device_or_business_dependencies
    result = isolated(<<~RUBY)
      require "net/connector/engine/core"
      puts JSON.generate(constants: %i[Configuration Dialogue Session Execution].map { |name| Net::Connector.const_get(name).name },
                         features: $LOADED_FEATURES)
    RUBY
    assert_equal 4, result.fetch("constants").size
    refute(result.fetch("features").any? { |path| path.match?(%r{/net/connector/(?:device|operations|vendor)(?:/|\.rb)}) })
    refute(result.fetch("features").any? { |path| path.include?("/textfsm") })
  end

  def test_public_api_defers_vendor_rules_and_parsing_until_used
    result = isolated(<<~RUBY)
      require "net/connector"
      puts JSON.generate(base: Net::Connector::Base.name, features: $LOADED_FEATURES)
    RUBY
    assert_equal "Net::Connector::Base", result.fetch("base")
    refute(result.fetch("features").any? { |path| path.include?("/net/connector/vendor/") || path.include?("/textfsm") })
    refute(result.fetch("features").any? { |path| path.include?("/operations/parse_output") || path.include?("/operations/tftp") })
  end

  def test_each_vendor_loads_its_own_profile_without_other_vendors_or_textfsm
    VENDORS.each do |vendor, name|
      result = isolated(<<~RUBY)
        require "net/connector/vendor/#{vendor}"
        klass = Net::Connector::#{name}::Connector
        puts JSON.generate(vendor: klass.vendor, commands: klass.profile.config_commands,
                           features: $LOADED_FEATURES)
      RUBY
      assert_equal vendor, result.fetch("vendor")
      refute_empty result.fetch("commands"), vendor
      # 无线 H3C 与 NX-OS 分别复用 H3C 和 IOS 的已有规则。
      allowed = [vendor, { "h3c_wireless" => "h3c", "cisco_nxos" => "cisco_ios" }[vendor]].compact
      loaded = result.fetch("features").filter_map { |path| path[%r{/net/connector/vendor/([^/.]+)}, 1] }.uniq
      assert_empty loaded - allowed, vendor
      refute result.fetch("features").any? { |path| path.include?("/textfsm") }, vendor
    end
  end

  def test_netdisco_and_offline_export_defer_textfsm_until_actual_parsing
    result = isolated(<<~'RUBY')
      require "net/connector/netdisco"
      require "tmpdir"
      require "stringio"
      parser_loaded = -> { $LOADED_FEATURES.any? { |path| path.include?("/textfsm") } }
      loaded_at_entry = parser_loaded.call
      Dir.mktmpdir do |directory|
        config = "interface Ethernet1/1\n description uplink\n!\n"
        File.binwrite(File.join(directory, "192.0.2.1.txt"), config)
        output = StringIO.new
        errors = StringIO.new
        status = Net::Connector::Netdisco::CLI.new(
          argv: ["--export", "192.0.2.1", "--directory", directory], env: {}, output: output, error: errors,
          fleet_factory: ->(*) { raise "offline export must not build Fleet" }
        ).run
        loaded_after_export = parser_loaded.call
        saved = Net::Connector::Operations::SavedConfig.new(directory: directory)
        rows = saved.parse(host: "192.0.2.1", template: "cisco_ios_running_config_interfaces.textfsm")
        puts JSON.generate(entry: loaded_at_entry, exported: loaded_after_export, parsed: parser_loaded.call,
                           status: status, errors: errors.string, exact_export: output.string == config, rows: rows)
      end
    RUBY
    refute result.fetch("entry")
    refute result.fetch("exported")
    assert result.fetch("parsed")
    assert_equal 0, result.fetch("status")
    assert_empty result.fetch("errors")
    assert result.fetch("exact_export")
    assert_equal [{ "INTERFACE" => "Ethernet1/1", "DESCRIPTION" => "uplink" }], result.fetch("rows")
  end

  def test_legacy_paths_and_constants_resolve_to_the_same_implementations_in_both_load_orders
    pairs = [
      ["operations/running_config/cisco", "vendor/cisco_ios/running_config", "Operations::RunningConfig::Cisco", "CiscoIos::RunningConfig"],
      ["operations/running_config/cisco", "vendor/cisco_nxos/running_config", "Operations::RunningConfig::CiscoNxos", "CiscoNxos::RunningConfig"],
      ["operations/running_config/hillstone", "vendor/hillstone/running_config", "Operations::RunningConfig::Hillstone", "Hillstone::RunningConfig"],
      ["operations/running_config/palo_alto", "vendor/palo_alto/running_config", "Operations::RunningConfig::PaloAlto", "PaloAlto::RunningConfig"]
    ]
    VENDORS.reject { |vendor, _| vendor == "h3c_wireless" }.each do |vendor, name|
      pairs << ["operations/tftp/#{vendor}", "vendor/#{vendor}/tftp_backup", "Operations::Tftp::#{name}", "#{name}::TftpBackup"]
    end
    { "cisco" => ["cisco_ios", "Cisco", "CiscoIos"], "h3c" => ["h3c", "H3c", "H3c"],
      "hillstone" => ["hillstone", "Hillstone", "Hillstone"], "palo_alto" => ["palo_alto", "PaloAlto", "PaloAlto"],
      "radware" => ["radware", "Radware", "Radware"] }.each do |old, (vendor, old_name, name)|
      pairs << ["operations/topology/#{old}", "vendor/#{vendor}/topology", "Operations::Topology::#{old_name}", "#{name}::Topology"]
    end
    [false, true].each do |reverse|
      script = pairs.map do |old_path, new_path, old_constant, new_constant|
        paths = reverse ? [new_path, old_path] : [old_path, new_path]
        paths.map { |path| "require #{"net/connector/#{path}".inspect}" }.join("\n") +
          "\nraise #{old_constant.inspect} unless Net::Connector::#{old_constant}.equal?(Net::Connector::#{new_constant})"
      end.join("\n")
      result = isolated(<<~RUBY)
        #{script}
        require "net/connector/engine/profile"
        require "net/connector/engine/base"
        require "net/connector/engine"
        require "net/connector"
        raise "collector alias" unless Net::Connector::Operations::RunningConfig.equal?(Net::Connector::RunningConfig)
        raise "topology workflow missing" unless Net::Connector::Operations::Topology.instance_methods.include?(:plan_descriptions)
        puts JSON.generate(base: Net::Connector::Base.name, profile: Net::Connector::Profile.name)
      RUBY
      assert_equal "Net::Connector::Base", result.fetch("base")
      assert_equal "Net::Connector::Profile", result.fetch("profile")
    end
  end

  private

  def isolated(script)
    output, errors, status = Open3.capture3(RbConfig.ruby, "-I#{LIBRARY}", "-rjson", "-e", script)
    assert status.success?, errors
    assert_empty errors
    JSON.parse(output)
  end
end
