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

  def test_device_entry_points_load_before_or_after_the_public_api
    paths = %w[net/connector/device/profile net/connector/device/running_config/strategy
               net/connector/device/running_config net/connector/device/local_backup
               net/connector/device/tftp/strategy net/connector/device/tftp
               net/connector/device/topology/strategy net/connector/device/topology
               net/connector/device/save_config net/connector/textfsm net/connector/device/base net/connector]
    [paths, paths.reverse].each do |order|
      result = isolated(<<~RUBY)
        #{order.map { |path| "require #{path.inspect}" }.join("\n")}
        puts JSON.generate(base: Net::Connector::Base.name, profile: Net::Connector::Profile.name,
                           collector: Net::Connector::RunningConfig.instance_methods.include?(:call),
                           features: $LOADED_FEATURES)
      RUBY
      assert_equal "Net::Connector::Base", result.fetch("base")
      assert_equal "Net::Connector::Profile", result.fetch("profile")
      assert result.fetch("collector")
      refute(result.fetch("features").any? { |path| path.include?("/net/connector/vendor/") || path.match?(%r{/lib/textfsm(?:/|\.rb)}) })
    end
  end

  def test_engine_core_has_no_device_or_business_dependencies
    result = isolated(<<~RUBY)
      require "net/connector/engine/core"
      puts JSON.generate(constants: %i[Configuration Dialogue Session Execution].map { |name| Net::Connector.const_get(name).name },
                         features: $LOADED_FEATURES)
    RUBY
    assert_equal 4, result.fetch("constants").size
    refute(result.fetch("features").any? { |path| path.match?(%r{/net/connector/(?:device|storage|textfsm|vendor)(?:/|\.rb)}) })
    refute(result.fetch("features").any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) })
  end

  def test_public_api_defers_vendor_rules_and_parsing_until_used
    result = isolated(<<~RUBY)
      require "net/connector"
      puts JSON.generate(base: Net::Connector::Base.name, features: $LOADED_FEATURES)
    RUBY
    assert_equal "Net::Connector::Base", result.fetch("base")
    refute(result.fetch("features").any? { |path| path.include?("/net/connector/vendor/") || path.match?(%r{/lib/textfsm(?:/|\.rb)}) })
    refute(result.fetch("features").any? { |path| path.include?("/net/connector/operations") })
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
      refute result.fetch("features").any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) }, vendor
    end
  end

  def test_storage_entry_points_are_independent_of_devices_and_support_both_load_orders
    paths = %w[net/connector/storage
               net/connector/storage/saved_config net/connector/storage/backup_lock
               net/connector/storage/private_file net/connector/storage/safe_file]
    [paths, paths.reverse].each do |order|
      result = isolated(<<~RUBY)
        #{order.map { |path| "require #{path.inspect}" }.join("\n")}
        puts JSON.generate(filename: Net::Connector::Storage::SavedConfig.filename("2001:db8::1"),
                           features: $LOADED_FEATURES)
      RUBY
      assert_equal "2001_db8__1.txt", result.fetch("filename")
      refute(result.fetch("features").any? { |path| path.match?(%r{/net/connector/(?:device|vendor)(?:/|\.rb)}) })
      refute(result.fetch("features").any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) })
    end
  end

  def test_netdisco_and_offline_export_defer_textfsm_until_actual_parsing
    result = isolated(<<~'RUBY')
      require "net/connector/netdisco"
      require "tmpdir"
      require "stringio"
      parser_loaded = -> { $LOADED_FEATURES.any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) } }
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
        saved = Net::Connector::Storage::SavedConfig.new(directory: directory)
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

  def test_vendor_strategies_load_before_or_after_the_public_api_without_compatibility_aliases
    VENDORS.each do |vendor, name|
      strategy_files = Dir[File.join(LIBRARY, "net/connector/vendor", vendor, "*.rb")]
      [false, true].each do |public_first|
        result = isolated(<<~RUBY)
          require "net/connector" if #{public_first}
          #{strategy_files.map { |path| "require #{path.inspect}" }.join("\n")}
          require "net/connector"
          klass = Net::Connector.vendor_class(#{vendor.inspect})
          profile = klass.profile
          raise "missing collection strategy" unless profile.running_config_strategy
          raise "missing transfer strategy" unless profile.tftp_strategy
          raise "topology workflow missing" unless Net::Connector::Topology.instance_methods.include?(:plan_interface_descriptions)
          raise "legacy operations namespace" if Net::Connector.const_defined?(:Operations, false)
          raise "legacy collection strategy" if (Net::Connector::RunningConfig.constants(false) & %i[Cisco CiscoNxos Hillstone PaloAlto]).any?
          raise "legacy transfer strategy" if (Net::Connector::Tftp.constants(false) & #{VENDORS.values.map(&:to_sym).inspect}).any?
          raise "legacy topology strategy" if (Net::Connector::Topology.constants(false) & %i[Cisco H3c Hillstone PaloAlto Radware]).any?
          puts JSON.generate(connector: klass.name, strategy: profile.tftp_strategy.name,
                             filename: profile.tftp_strategy.filename("192.0.2.1"), features: $LOADED_FEATURES)
        RUBY
        assert_equal "Net::Connector::#{name}::Connector", result.fetch("connector")
        assert_match(/::TftpBackup\z/, result.fetch("strategy"))
        refute_empty result.fetch("filename")
        allowed = [vendor, { "h3c_wireless" => "h3c", "cisco_nxos" => "cisco_ios" }[vendor]].compact
        loaded = result.fetch("features").filter_map { |path| path[%r{/net/connector/vendor/([^/.]+)}, 1] }.uniq
        assert_empty loaded - allowed, vendor
        refute result.fetch("features").any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) }, vendor
      end
    end
  end

  private

  def isolated(script)
    output, errors, status = Open3.capture3(RbConfig.ruby, "-w", "-I#{LIBRARY}", "-rjson", "-e", script)
    assert status.success?, errors
    assert_empty errors
    JSON.parse(output)
  end
end
