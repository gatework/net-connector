# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"

class ModuleLoadingTest < Minitest::Test
  LIBRARY = File.expand_path("../lib", __dir__)
  VENDORS = { "h3c" => "H3c", "h3c_wireless" => "H3cWireless", "cisco_ios" => "CiscoIos",
              "cisco_nxos" => "CiscoNxos", "huawei" => "Huawei", "hillstone" => "Hillstone",
              "palo_alto" => "PaloAlto", "radware" => "Radware",
              "topsec" => "Topsec", "fortinet" => "Fortinet", "juniper" => "Juniper", "centec" => "Centec" }.freeze

  def test_device_entry_points_load_before_or_after_the_public_api
    paths = %w[net/connector/device/profile net/connector/device/running_config/strategy
               net/connector/device/running_config net/connector/device/local_backup net/connector/device/remote_backup/target
               net/connector/device/remote_backup/receipt net/connector/device/remote_backup
               net/connector/device/tftp/strategy net/connector/device/tftp
               net/connector/device/interfaces/name net/connector/device/interfaces/description
               net/connector/device/interfaces/strategy net/connector/device/interfaces/blocks net/connector/device/interfaces/quoted_text net/connector/device/interfaces
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

  def test_collection_progress_loads_independently_and_reuses_the_shared_progress_contract
    result = isolated(<<~RUBY)
      require "stringio"
      require "net/connector/collect/progress"
      output = StringIO.new
      progress = Net::Connector::Collect::Progress.new(io: output)
      device = { "host" => "192.0.2.1" }
      item = { "target" => device, "status" => "complete", "report_saved" => true, "duration_ms" => 1 }
      progress.with_updates do
        progress.plan(devices: [device], total: 2, parallel: 3, label: "采集")
        progress.start(device)
        progress.result(item)
      end
      progress.finish("status" => "complete", "devices" => [item], "pending" => [], "directory" => "/tmp/fixture-report")
      legacy_entry = begin
        require #{File.join(LIBRARY, "net/connector/collection_progress").inspect}
        true
      rescue LoadError
        false
      end
      puts JSON.generate(superclass: Net::Connector::Collect::Progress.superclass.name, output: output.string,
                         legacy_constant: Net::Connector.const_defined?(:CollectionProgress, false),
                         legacy_entry: legacy_entry, features: $LOADED_FEATURES)
    RUBY
    assert_equal "Net::Connector::Progress", result.fetch("superclass")
    assert_includes result.fetch("output"), "succeeded 1, partial 0, failed 0, skipped 1"
    assert_includes result.fetch("output"), "summary.json"
    refute result.fetch("legacy_constant")
    refute result.fetch("legacy_entry")
    refute(result.fetch("features").any? { |path| path.match?(%r{/net/connector/(?:netdisco|device|vendor)(?:/|\.rb)}) })
  end

  def test_cancelled_known_hosts_dependency_load_preserves_the_original_failure
    result = isolated(<<~'RUBY')
      require "tmpdir"
      require "net/connector/engine/core"
      Dir.mktmpdir do |directory|
        configuration = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit",
                                                           known_hosts: File.join(directory, "known_hosts"))
        entry = Net::Connector::KnownHosts.new(configuration)
        original = Interrupt.new("dependency load cancelled")
        entry.define_singleton_method(:require_relative) { |_| raise original }
        observed = begin
          entry.commit
        rescue Exception => error
          error
        end
        puts JSON.generate(type: observed.class.name, original: observed.equal?(original))
      ensure
        entry&.close
      end
    RUBY
    assert_equal "Interrupt", result.fetch("type")
    assert result.fetch("original")
  end

  def test_protocol_objects_load_without_the_response_loop_or_redaction_runtime
    result = isolated(<<~'RUBY')
      require "net/connector/engine/dialogue"
      require "net/connector/engine/response"
      interaction = Net::Connector::Interaction.new(/Continue:\z/, "yes\n")
      response = Net::Connector::Response.new(raw: "router#", output: "router#", prompt: "router#")
      error = Net::Connector::DeviceError.new("rejected", phase: :command)
      puts JSON.generate(reply: interaction.response("Continue:"), prompt: response.prompt,
                         error_code: error.code, features: $LOADED_FEATURES)
    RUBY
    assert_equal "yes\n", result.fetch("reply")
    assert_equal "router#", result.fetch("prompt")
    assert_equal "device_error", result.fetch("error_code")
    refute(result.fetch("features").any? { |path| path.match?(%r{/(?:expect|net/connector/engine/(?:session|redactor|response_reader|transport))(?:/|\.rb)}) })
  end

  def test_redactor_and_response_reader_support_independent_loading
    paths = %w[net/connector/engine/redactor net/connector/engine/response_reader net/connector/engine/core]
    [paths, paths.reverse].each do |order|
      result = isolated(<<~RUBY)
        #{order.map { |path| "require #{path.inspect}" }.join("\n")}
        redactor = Net::Connector::Redactor.new("fixture-token")
        redactor.with_scope { redactor.remember("temporary") }
        puts JSON.generate(redacted: redactor.call("fixture-token temporary"),
                           reader: Net::Connector::ResponseReader.instance_methods(false).include?(:read))
      RUBY
      assert_equal "[REDACTED] temporary", result.fetch("redacted")
      assert result.fetch("reader")
    end
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
        klass = Net::Connector::Vendor::#{name}
        puts JSON.generate(vendor: klass.vendor, commands: klass.profile.config_commands,
                           features: $LOADED_FEATURES)
      RUBY
      assert_equal vendor, result.fetch("vendor")
      refute_empty result.fetch("commands"), vendor
      # 无线 H3C 复用 H3C；IOS 与 NX-OS 复用 Cisco 公共协议。
      allowed = [vendor, { "h3c_wireless" => "h3c", "cisco_nxos" => "cisco", "cisco_ios" => "cisco" }[vendor]].compact
      loaded = result.fetch("features").filter_map { |path| path[%r{/net/connector/vendor/([^/.]+)}, 1] }.uniq
      assert_empty loaded - allowed, vendor
      refute result.fetch("features").any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) }, vendor
    end
  end

  def test_storage_entry_points_are_independent_of_devices_and_support_both_load_orders
    paths = %w[net/connector/storage
               net/connector/storage/saved_config net/connector/storage/backup_lock
               net/connector/storage/atomic_file net/connector/storage/file_reader
               net/connector/storage/batch_directory]
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

  def test_netdisco_helpers_support_both_load_orders
    paths = %w[net/connector/netdisco/cli/options net/connector/netdisco/cli/credentials net/connector/netdisco/cli/backup
               net/connector/netdisco/cli/topology net/connector/netdisco/report/text net/connector/netdisco]
    [paths, paths.reverse].each do |order|
      result = isolated(<<~RUBY)
        #{order.map { |path| "require #{path.inspect}" }.join("\n")}
        values = Net::Connector::Netdisco::CLI::Options.parse(argv: ["--parallel", "7"])
        puts JSON.generate(parallel: values[:environment]["NC_PARALLEL"],
                           connection: Net::Connector::Netdisco::CLI::Credentials.respond_to?(:resolve),
                           text: Net::Connector::Netdisco::Report::Text.respond_to?(:write))
      RUBY
      assert_equal "7", result.fetch("parallel")
      assert result.fetch("connection")
      assert result.fetch("text")
    end
  end

  def test_netdisco_entry_points_declare_their_dependencies
    cases = {
      "config" => 'N::Config.parse("backup" => { "parallel" => 2 }) == { "NC_PARALLEL" => "2" }',
      "config/initializer" => 'require "tmpdir"; require "stringio"; Dir.mktmpdir { |root| path = File.join(root, "settings.yml"); N::Config::Initializer.new(output: StringIO.new).create(path: path, document: {}, interactive: false) == :created && N::Config.load(path).empty? }',
      "device/policy" => 'N::Device::Policy.new({ h3c: "startup.cfg" }, vendors: [:h3c]) { |value| value }.for(vendor: :h3c, host: "192.0.2.1") == "startup.cfg"',
      "topology/options" => 'N::Topology::Options.new.format(neighbor: "edge", port: "Gi1") == "To_edge_Gi1"',
      "inventory" => "N::Inventory.options.fetch(:page_size) == 500",
      "inventory/budget" => "N::Inventory::Budget.new(N::Inventory.options, clock: -> { 0 }).remaining == 300",
      "inventory/http" => 'N::Inventory::HTTP.new(url: "https://inventory.example", api_key: "fixture").respond_to?(:devices)',
      "inventory/postgres" => "N::Inventory::Postgres.options(query: 'SELECT ip FROM device').fetch(:page_size) == 500",
      "device/access" => "N::Device::Access.respond_to?(:resolve)",
      "settings" => "N::Settings.new(env: {}).public_config.fetch(:backup).fetch(:parallel) == 4",
      "cli/options" => 'N::CLI::Options.settings(N::CLI::Options.parse(argv: ["--parallel", "7"]), env: {}, configuration: N::CLI::Options.configuration({ environment: {} }, env: {}, directories: [])).parallel == 7',
      "cli/credentials" => "N::CLI::Credentials.respond_to?(:resolve)",
      "cli/backup" => 'require "stringio"; output = StringIO.new; N::CLI::Backup.new(configuration_options: { directories: [] }, argv: ["--help"], output: output).run.zero? && output.string.include?("--parallel")',
      "cli/topology" => 'require "stringio"; output = StringIO.new; N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--help"], output: output).run.zero? && output.string.include?("--apply")',
      "inventory/cache" => 'inventory = Struct.new(:devices).new([]); N::Inventory::Cache.new(inventory: inventory, directory: "unused-cache", identity: "test").status.nil?',
      "report/store" => "N::Report::Store::Json.new.respond_to?(:write)",
      "tftp/verifier" => "N::Tftp::Verifier.new.respond_to?(:upload_and_verify)",
      "tftp/archive" => "N::Tftp::Archive.instance_methods.include?(:upload_filename)",
      "operation" => 'N::Operation.new(settings: N::Settings.new(env: {}), inventory: ->(_) { raise "empty batch must not read inventory" }).execute_scripts(scripts: {}, confirmed: true).status == :no_devices',
      "operation/batch" => "now = Time.now.utc; N::Operation::Batch.new(operation: :execute_scripts, outcomes: [], callback_errors: [], started_at: now, finished_at: now).to_h.fetch(:status) == :no_devices",
      "planner" => "N::Planner.new([]).call(mode: :backup, limit_per_vendor: nil).validate!.selected.empty?",
      "fleet" => "inventory = Object.new; def inventory.devices = []; N::Fleet.new(inventory: inventory, settings: N::Settings.new(env: {})).plan_backup.selected.empty?",
      "progress" => 'require "stringio"; N::Progress.new(io: StringIO.new).event(nil).nil?',
      "cli" => 'require "stringio"; output = StringIO.new; N::CLI.new(configuration_options: { directories: [] }, argv: ["--version"], env: {}, output: output).run.zero? && output.string.strip == Net::Connector::VERSION'
    }
    cases.each do |entry, expression|
      result = isolated(<<~RUBY)
        require "net/connector/netdisco/#{entry}"
        N = Net::Connector::Netdisco
        value = begin; #{expression}; end
        puts JSON.generate(value: value, features: $LOADED_FEATURES)
      RUBY
      assert result.fetch("value"), entry
      refute(result.fetch("features").any? { |path| path.end_with?("/net/connector/netdisco.rb") }, entry)
    end
  end

  def test_inventory_domain_and_postgres_do_not_load_the_http_adapter
    %w[inventory inventory/budget inventory/cache inventory/postgres device].each do |entry|
      result = isolated(<<~RUBY)
        require "net/connector/netdisco/#{entry}"
        puts JSON.generate(features: $LOADED_FEATURES)
      RUBY
      refute result.fetch("features").any? { |path| path.end_with?("/netdisco/inventory/http.rb") }, entry
    end
  end

  def test_engine_values_load_from_their_own_files
    cases = {
      "script" => 'C::Script.parse("show version\n").size == 1',
      "interaction" => 'C::Interaction.new(/confirm/, "yes").response("confirm") == "yes"',
      "response" => 'C::Response.new(raw: "raw", output: "out", prompt: "#").prompt == "#"',
      "command/result" => 'C::Command::Result.new(command: C::Command.new("show"), output: "out", prompt: "#", duration: 0).output == "out"',
      "terminal/text" => 'C::Terminal::Text.render("ready") == "ready"',
      "terminal/renderer" => 'C::Terminal::Renderer.render("before\rready") == "readye"',
      "error/metadata" => "C::Error::Metadata.code(:command_timeout) == :command_timeout",
      "transports" => 'C::Event.new(index: 0, match: "ready").matched?'
    }
    cases.each do |entry, expression|
      result = isolated(<<~RUBY)
        require "net/connector/engine/#{entry}"
        C = Net::Connector
        puts JSON.generate(value: (#{expression}), features: $LOADED_FEATURES)
      RUBY
      assert result.fetch("value"), entry
      refute(result.fetch("features").any? { |path| path.end_with?("/net/connector/device/base.rb") }, entry)
    end
  end

  def test_net_backup_executable_exports_offline_without_loading_optional_drivers
    result = isolated(<<~'RUBY')
      require "tmpdir"
      require "stringio"
      Dir.mktmpdir do |directory|
        config = "interface Ethernet1/1\n description offline\n!\n"
        File.binwrite(File.join(directory, "192.0.2.1.txt"), config)
        ARGV.replace(["--export", "192.0.2.1", "--directory", directory])
        ENV.delete_if { |key, _| key.start_with?("NC_", "ND_", "NETDISCO_", "TFTP_") }
        output, errors = StringIO.new, StringIO.new
        $stdout, $stderr = output, errors
        begin
          load File.expand_path("../bin/net-backup", $LOAD_PATH.first)
        rescue SystemExit => exit_status
          status = exit_status.status
        ensure
          $stdout, $stderr = STDOUT, STDERR
        end
        puts JSON.generate(status: status, exported: output.string == config, errors: errors.string,
                           optional_loaded: $LOADED_FEATURES.any? { |path| path.match?(%r{/lib/(?:textfsm|pg)(?:/|\.rb)}) })
      end
    RUBY
    assert_equal 0, result.fetch("status")
    assert result.fetch("exported")
    assert_empty result.fetch("errors")
    refute result.fetch("optional_loaded")
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
        status = Net::Connector::Netdisco::CLI.new(configuration_options: { directories: [] },
          argv: ["--export", "192.0.2.1", "--directory", directory], env: {}, output: output, error: errors,
          fleet_factory: ->(*) { raise "offline export must not build Fleet" }
        ).run
        loaded_after_export = parser_loaded.call
        saved = Net::Connector::Storage::SavedConfig.new(directory: directory)
        rows = saved.parse(host: "192.0.2.1", template: "cisco/show_running_config.textfsm")
        puts JSON.generate(entry: loaded_at_entry, exported: loaded_after_export, parsed: parser_loaded.call,
                           postgres_loaded: $LOADED_FEATURES.any? { |path| path.end_with?("/pg.rb") },
                           status: status, errors: errors.string, exact_export: output.string == config, rows: rows)
      end
    RUBY
    refute result.fetch("entry")
    refute result.fetch("exported")
    refute result.fetch("postgres_loaded")
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
          raise "wrong transfer capability" unless !!profile.tftp_strategy == #{!%w[topsec juniper].include?(vendor)}
          raise "interface workflow missing" unless Net::Connector::Interfaces.instance_methods.include?(:plan)
          raise "legacy operations namespace" if Net::Connector.const_defined?(:Operations, false)
          raise "legacy collection strategy" if (Net::Connector::RunningConfig.constants(false) & %i[Cisco CiscoNxos Hillstone PaloAlto]).any?
          raise "legacy transfer strategy" if (Net::Connector::Tftp.constants(false) & #{VENDORS.values.map(&:to_sym).inspect}).any?
          raise "legacy topology strategy" if (Net::Connector::Interfaces.constants(false) & %i[Cisco H3c Hillstone PaloAlto Radware]).any?
          puts JSON.generate(connector: klass.name, strategy: profile.tftp_strategy&.name,
                             filename: profile.tftp_strategy&.filename("192.0.2.1"), features: $LOADED_FEATURES)
        RUBY
        assert_equal "Net::Connector::Vendor::#{name}", result.fetch("connector")
        if %w[topsec juniper].include?(vendor)
          assert_nil result.fetch("strategy")
          assert_nil result.fetch("filename")
        else
          assert_match(/::Tftp\z/, result.fetch("strategy"))
          refute_empty result.fetch("filename")
        end
        allowed = [vendor, { "h3c_wireless" => "h3c", "cisco_nxos" => "cisco", "cisco_ios" => "cisco" }[vendor]].compact
        loaded = result.fetch("features").filter_map { |path| path[%r{/net/connector/vendor/([^/.]+)}, 1] }.uniq
        assert_empty loaded - allowed, vendor
        refute result.fetch("features").any? { |path| path.match?(%r{/lib/textfsm(?:/|\.rb)}) }, vendor
      end
    end
  end

  # 本地归档只加载本地依赖；选择 SSH 根目录时才加载并构造远端归档器。
  def test_archive_factory_loads_ssh_only_when_selecting_a_remote_root
    result = isolated(<<~'RUBY')
      require "net/connector/netdisco/tftp/archive"
      require "tmpdir"
      loaded = -> { $LOADED_FEATURES.any? { |path| path.end_with?("/ssh/archive/client.rb") } }
      before = loaded.call
      Dir.mktmpdir do |directory|
        archive = Net::Connector::Netdisco::Tftp::Archive.new(directory: directory, root: "ssh://reader@192.0.2.10/srv")
        puts JSON.generate(before: before, after: loaded.call, type: archive.class.name)
        archive.close
      end
    RUBY
    refute result.fetch("before")
    assert result.fetch("after")
    assert_equal "Net::Connector::Netdisco::SSH::Archive::Pool", result.fetch("type")
  end

  # 独立加载 SSH 归档后仍须具备完整错误边界，启动失败不能退化为 NameError。
  def test_ssh_archive_declares_its_failure_dependencies_without_loading_the_netdisco_entry
    result = isolated(<<~'RUBY')
      require "net/connector/netdisco/ssh/archive/client"
      require "tmpdir"
      device = Object.new
      def device.host = "192.0.2.1"
      def device.tftp_filename = "fixture.cfg"
      def device.backup_filename(**) = "fixture.txt"
      Dir.mktmpdir do |directory|
        archive = Net::Connector::Netdisco::SSH::Archive::Client.new(
          directory: directory, root: "ssh://reader@192.0.2.10/srv",
          launcher: ->(&_) { raise IOError, "fixture launch failed" }
        )
        begin
          archive.upload_and_archive(device, started_at: Time.now.utc) { raise "device must not run" }
        rescue StandardError => error
          puts JSON.generate(error: error.class.name, code: error.respond_to?(:code) ? error.code : nil,
                             facade_loaded: $LOADED_FEATURES.any? { |path| path.end_with?("/net/connector/netdisco.rb") })
        end
      end
    RUBY
    assert_equal "Net::Connector::Netdisco::Tftp::Archive::Failure", result.fetch("error")
    assert_equal "tftp_archive_failed", result.fetch("code")
    refute result.fetch("facade_loaded")
  end

  # 认证可以独立使用；归档统一入口公开新命名空间，旧常量不保留别名。
  def test_ssh_archive_entry_and_authentication_have_explicit_loading_boundaries
    result = isolated(<<~'RUBY')
      require "net/connector/netdisco/ssh/authentication"
      authentication_loaded_tftp = $LOADED_FEATURES.any? { |path| path.include?("/netdisco/tftp/") }
      require "net/connector/netdisco/ssh/archive"
      namespace = Net::Connector::Netdisco
      puts JSON.generate(authentication_loaded_tftp: authentication_loaded_tftp,
                         types: [namespace::SSH::Authentication.name, namespace::SSH::Archive::Client.name,
                                 namespace::SSH::Archive::Pool.name],
                         legacy_namespace: namespace.const_defined?(:Ssh, false),
                         old_aliases: %i[SshArchive SshArchivePool SshAuthentication].any? { |name| namespace::Tftp.const_defined?(name, false) })
    RUBY
    refute result.fetch("authentication_loaded_tftp")
    refute result.fetch("legacy_namespace")
    refute result.fetch("old_aliases")
    assert_equal %w[Net::Connector::Netdisco::SSH::Authentication Net::Connector::Netdisco::SSH::Archive::Client
                    Net::Connector::Netdisco::SSH::Archive::Pool], result.fetch("types")
  end

  # 单数入口独立声明依赖，复数旧常量不再作为兼容入口出现。
  def test_operation_uses_singular_namespace_without_legacy_alias
    result = isolated(<<~'RUBY')
      require "net/connector/netdisco/operation"
      namespace = Net::Connector::Netdisco
      puts JSON.generate(type: namespace::Operation.name,
                         outcome: namespace::Operation::Outcome.name,
                         legacy: namespace.const_defined?(:Operations, false))
    RUBY
    assert_equal "Net::Connector::Netdisco::Operation", result.fetch("type")
    assert_equal "Net::Connector::Netdisco::Operation::Outcome", result.fetch("outcome")
    refute result.fetch("legacy")
  end

  # 单设备资源提供短动作，批量入口继续返回批次；获取资源不能隐式访问设备。
  def test_interface_resource_and_batch_operations_expose_their_own_contracts
    result = isolated(<<~'RUBY')
      require "net/connector"
      require "net/connector/netdisco/fleet"
      device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "audit")
      resource = device.interfaces
      batch_types = [Net::Connector::Netdisco::Fleet, Net::Connector::Netdisco::Operation]
      batch_actions = %i[plan_descriptions apply_descriptions sync_descriptions]
      puts JSON.generate(batch: batch_types.all? { |type| (batch_actions - type.public_instance_methods).empty? },
                         resource: %i[neighbors descriptions plan audit apply sync].all? { |name| resource.respond_to?(name) },
                         offline: !device.connected?, type: resource.class.name)
    RUBY
    assert result.fetch("batch")
    assert result.fetch("resource")
    assert result.fetch("offline")
    assert_equal "Net::Connector::Interfaces", result.fetch("type")
  end

  private

  def isolated(script)
    script = "preloaded_features = $LOADED_FEATURES.dup\n" + script.gsub("$LOADED_FEATURES", "($LOADED_FEATURES - preloaded_features)")
    output, errors, status = Open3.capture3(RbConfig.ruby, "-w", "-I#{LIBRARY}", "-rjson", "-e", script)
    assert status.success?, errors
    assert_empty errors
    JSON.parse(output)
  end
end
