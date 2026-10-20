# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco/cli/topology"
require_relative "support/topology_fixture"

class CLITopologyTest < Minitest::Test
  N = Net::Connector::Netdisco
  C = Net::Connector

  def test_help_is_offline_and_does_not_create_default_configuration
    Dir.mktmpdir do |root|
      output = StringIO.new
      status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--help"], env: {}, default_config: File.join(root, "topology.yml"),
                                  default_directory: root, output: output, error: StringIO.new).run
      assert_equal 0, status
      assert_includes output.string, "--apply"
      assert_empty Dir.children(root)
    end
  end

  def test_inventory_only_filters_names_without_device_credentials_or_report_directory
    inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "name" => "edge01", "vendor" => "H3C" },
                                        { "ip" => "192.0.2.2", "name" => "core01", "vendor" => "H3C" }])
    output = StringIO.new
    N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "inventory-only requested device credentials" }]) do
      status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--inventory-only", "--name", "edge", "--json"], env: {}, output: output, error: StringIO.new).run
      assert_equal 0, status
    end
    assert_equal(["192.0.2.1"], JSON.parse(output.string).fetch("devices").map { |device| device.fetch("host") })
  end

  def test_apply_requires_and_persists_a_fresh_plan_before_device_application
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "name" => "edge01", "vendor" => "H3C" }])
      plan = C::Interfaces::Plan.new(host: "192.0.2.1", vendor: :h3c, evidence: {}, changes: [], commands: [])
      calls = []
      factory = lambda do |*|
        Object.new.tap do |connector|
          connector.define_singleton_method(:interfaces) { self }
          connector.define_singleton_method(:audit) { |**_options, &_format| calls << :plan; C::Interfaces::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false) }
          connector.define_singleton_method(:apply) do |value, confirmed:|
            assert = Dir.glob(File.join(root, "*", "plan.json"))
            raise "plan not persisted before apply" unless assert.size == 1 && File.file?(assert.first + ".sha256")
            raise "unconfirmed or different plan" unless confirmed && value.equal?(plan)

            calls << :apply
            C::Result.new
          end
          connector.define_singleton_method(:close) { calls << :close }
        end
      end
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--apply", "--json", "--no-progress"], env: {}, default_directory: root,
                                    connector_factory: factory, output: output, error: error).run
        assert_equal 0, status, error.string
      end
      assert_equal [:plan, :close, :apply, :close], calls
      assert_equal true, JSON.parse(output.string).fetch("success")
      assert_equal 1, Dir.glob(File.join(root, "*", "summary.txt")).size
    end
  end

  def test_yaml_apply_is_not_sufficient_authorization
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      File.write(path, { "topology" => { "mode" => "apply", "directory" => root } }.to_yaml)
      N::CLI::Credentials.stub(:resolve, ->(*) { flunk "unconfirmed apply read inventory" }) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: [], env: {}, default_config: path, output: StringIO.new, error: StringIO.new).run
        assert_equal 2, status
      end
      assert_equal ["topology.yml"], Dir.children(root)
    end
  end

  def test_one_bad_credential_resolver_does_not_abort_other_devices
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new((1..2).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "H3C" } })
      resolver = lambda do |device|
        raise IOError, "private credential source" if device.host.end_with?(".1")

        { username: "audit" }
      end
      calls = []
      factory = lambda do |device, _options|
        Object.new.tap do |connector|
          connector.define_singleton_method(:interfaces) { self }
          connector.define_singleton_method(:audit) do |**_options, &_format|
            calls << device.host
            plan = C::Interfaces::Plan.new(host: device.host, vendor: device.vendor, evidence: {}, changes: [], commands: [])
            C::Interfaces::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false)
          end
          connector.define_singleton_method(:close) {}
        end
      end
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, resolver]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--plan", "--json"], env: {}, default_directory: root,
                                    connector_factory: factory, output: output, error: error).run
        assert_equal 1, status, error.string
      end
      assert_equal ["192.0.2.2"], calls
      refute_includes output.string + error.string, "private credential source"
      assert_equal(["failed", "planned"], JSON.parse(output.string).fetch("devices").map { |device| device.fetch("status") })
    end
  end

  def test_partial_audit_applies_verified_subset_and_keeps_unverified_issues_in_report
    fixture = TopologyFixture.new(:h3c, neighbor: TopologyFixture::SAMPLES.fetch(:h3c).fetch(:neighbor) +
      "GE1/0/2 000f-e25d-ee92 GE1/0/3 other\nGE1/0/2 000f-e25d-ee93 GE1/0/4 duplicate\n")
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "name" => "edge", "vendor" => "H3C" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--apply", "--json", "--no-progress"], env: {}, default_directory: root,
                                    connector_factory: lambda { |*|
                                      fixture.transport.events << fixture.prompt if fixture.transport.opens.positive? && fixture.transport.closed?
                                      fixture.device
                                    }, output: output, error: error).run
        assert_equal 1, status, error.string
      end
      item = JSON.parse(output.string).fetch("devices").first
      assert_equal "partial_applied", item.fetch("status"), item.inspect
      assert_equal "ambiguous_neighbor", item.fetch("issues").first.fetch("code")
      assert_equal "To_peer_Gi1/0/2", fixture.description
      assert_equal(1, fixture.observed.count { |command, _| command == fixture.sample.fetch(:save) })
    end
  ensure
    fixture&.close
  end

  def test_application_failure_keeps_completed_steps_and_does_not_replay_changes
    fixture = TopologyFixture.new(:h3c)
    fixture.save_output = "not a confirmed save"
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "vendor" => "H3C" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--apply", "--json", "--no-progress"], env: {}, default_directory: root,
                                    connector_factory: lambda { |*|
                                      fixture.transport.events << fixture.prompt if fixture.transport.opens.positive? && fixture.transport.closed?
                                      fixture.device
                                    }, output: output, error: error).run
        assert_equal 1, status, error.string
      end
      item = JSON.parse(output.string).fetch("devices").first
      assert_equal "partial", item.fetch("status"), item.inspect
      assert_operator item.fetch("steps"), :>, 0
      assert_equal "persistence_unconfirmed", item.fetch("diagnostic").fetch("error_code")
      assert_equal(1, fixture.observed.count { |command, _| command == fixture.sample.fetch(:save) })
    end
  ensure
    fixture&.close
  end

  def test_progress_failure_is_reported_after_device_work_finishes
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      completed = []
      factory = audit_factory(completed)
      broken = Object.new
      broken.define_singleton_method(:puts) { |*| raise IOError, "private output failure" }
      output = StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--discover", "--json"], env: {}, default_directory: root,
                                    connector_factory: factory, output: output, error: broken).run
        assert_equal 1, status
      end
      assert_equal [:audit, :close], completed
      report = JSON.parse(File.read(Dir.glob(File.join(root, "*", "summary.json")).fetch(0)))
      assert_equal false, report.fetch("success")
      assert report.fetch("progress_error")
      refute_includes JSON.generate(report), "private output failure"
    end
  end

  def test_interruption_closes_connector_and_persists_interrupted_report
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      completed = []
      factory = audit_factory(completed, interrupt: true)
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--plan", "--no-progress"], env: {}, default_directory: root,
                                    connector_factory: factory, output: StringIO.new, error: StringIO.new).run
        assert_equal 130, status
      end
      assert_equal [:audit, :close], completed
      report = JSON.parse(File.read(Dir.glob(File.join(root, "*", "summary.json")).fetch(0)))
      assert_equal false, report.fetch("success")
      assert_equal "interrupted", report.fetch("devices").first.fetch("status")
      assert_equal true, report.fetch("interrupted")
    end
  end

  def test_plan_persistence_failure_prevents_application_and_preserves_collected_audit
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      completed = []
      writer = C::Storage::AtomicFile.method(:write)
      failing_writer = lambda do |path, *args, **options|
        raise IOError, "private plan output failure" if path.end_with?("plan.json.sha256")

        writer.call(path, *args, **options)
      end
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        C::Storage::AtomicFile.stub(:write, failing_writer) do
          status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--apply", "--no-progress"], env: {}, default_directory: root,
                                      connector_factory: audit_factory(completed), output: StringIO.new, error: StringIO.new).run
          assert_equal 2, status
        end
      end
      assert_equal [:audit, :close], completed
      report = JSON.parse(File.read(Dir.glob(File.join(root, "*", "summary.json")).fetch(0)))
      assert_equal false, report.fetch("success")
      assert_equal "planned", report.fetch("devices").first.fetch("status")
      assert_equal "IOError", report.fetch("orchestration_error_type")
    end
  end

  def test_unsupported_discovery_is_skipped_and_does_not_consume_target_limit
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Radware" },
                                            { "ip" => "192.0.2.2", "vendor" => "H3C" }])
      completed, output, error = [], StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--discover", "--limit", "1", "--json", "--no-progress"], env: {}, default_directory: root,
                                    connector_factory: audit_factory(completed), output: output, error: error).run
        assert_equal 0, status, error.string
      end
      assert_equal [:audit, :close], completed
      report = JSON.parse(output.string)
      assert_equal({ "unsupported_operation" => 1, "discovered" => 1 }, report.fetch("counts"))
      assert_equal 2, File.readlines(Dir.glob(File.join(root, "*", "events.jsonl")).fetch(0)).size
    end
  end

  def test_stdin_apply_requires_run_frame_before_creating_reports_or_connecting
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "unconfirmed apply requested device credentials" }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--apply", "--stdin-credentials", "--no-progress"], env: {},
                                    default_directory: root, input: StringIO.new("DECLINE\n"),
                                    output: StringIO.new, error: StringIO.new).run
        assert_equal 1, status
      end
      assert_empty Dir.children(root)
    end
  end

  def test_help_levels_and_examples_are_offline_and_mode_specific
    { "--help" => false, "--help-all" => true, "--examples" => false }.each do |flag, detailed|
      output = StringIO.new
      N::CLI::Credentials.stub(:resolve, ->(*) { flunk "help queried inventory" }) do
        assert_equal 0, N::CLI::Topology.new(configuration_options: { directories: [] }, argv: [flag], env: {}, output: output, error: StringIO.new).run
      end
      if flag == "--examples"
        assert_includes output.string, "--inventory-only"
        assert_includes output.string, "--apply"
      else
        %w[--discover --plan --apply --inventory-only --parallel --limit --examples].each do |option|
          assert_includes output.string, option
        end
        assert_equal detailed, output.string.include?("--description-format")
        assert_includes output.string, "拓扑报告目录"
        refute_includes output.string, "备份目录"
        refute_includes output.string, "--sample"
      end
    end
  end

  def test_missing_configuration_has_complete_public_defaults_and_stops
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      N::CLI::Credentials.stub(:resolve, ->(*) { flunk "initialization queried inventory" }) do
        status = N::CLI::Topology.new(configuration_options: { directories: [], home: root }, argv: ["--init", "--non-interactive", "--env-file", File.join(root, ".env")], env: {}, default_config: path,
                                    output: StringIO.new, error: StringIO.new).run
        assert_equal 0, status
      end
      document = YAML.safe_load_file(path)
      assert_equal %w[inventory netdisco ssh topology], document.keys.sort
      assert_equal File.expand_path("topologys"), document.dig("topology", "directory")
      assert_equal "plan", document.dig("topology", "mode")
      assert_equal "To_%{neighbor}_%{port}", document.dig("topology", "description_format")
      assert_equal %w[.env topology.yml], Dir.children(root).sort
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_inventory_preview_reports_selection_and_sanitizes_terminal_text
    inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "name" => "edge\e[31m", "vendor" => "H3C" },
                                          { "ip" => "192.0.2.2", "name" => "core", "vendor" => "H3C" }])
    output = StringIO.new
    N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "preview connected" }]) do
      status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--inventory-only", "--name", "edge", "--no-progress"], env: {},
                                  output: output, error: StringIO.new).run
      assert_equal 0, status
    end
    assert_includes output.string, "清单 2 台；本次 1 台；跳过 1 台"
    assert_includes output.string, "h3c"
    refute_includes output.string, "\e"
  end

  def test_invalid_topology_limit_does_not_advertise_backup_sampling
    error = StringIO.new
    assert_equal 2, N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--limit", "0"], env: {}, output: StringIO.new, error: error).run
    assert_includes error.string, "设备上限须为正整数"
    refute_includes error.string, "抽样"
  end

  def test_report_directory_and_parallel_cli_overrides_take_precedence_over_yaml
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      destination = File.join(root, "chosen")
      File.write(path, { "topology" => { "directory" => File.join(root, "unused"), "parallel" => 1 } }.to_yaml)
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      output, completed, requested = StringIO.new, [], []
      prepare = ->(parallel:) { requested << parallel }
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        Net::Connector::Resources.stub(:prepare!, prepare) do
          status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--discover", "--directory", destination, "--parallel", "500", "--quiet"],
                                      env: {}, default_config: path, default_directory: File.join(root, "default"),
                                      connector_factory: audit_factory(completed), output: output, error: StringIO.new).run
          assert_equal 0, status
        end
      end
      assert_equal [:audit, :close], completed
      assert_equal [1], requested
      assert_includes output.string, "结果：完成；模式：discover"
      %w[plan.json summary.json summary.txt].each do |filename|
        artifact = Dir.glob(File.join(destination, "*", filename)).fetch(0)
        assert_includes output.string, artifact
      end
      refute File.exist?(File.join(root, "unused"))
      refute File.exist?(File.join(root, "default"))
    end
  end

  def test_cache_fallback_and_write_failure_are_visible_in_inventory_preview
    output, error = StringIO.new, StringIO.new
    device = N::Device.new(**N::Device.members.to_h { |key| [key, nil] }.merge(host: "192.0.2.1", name: "edge", vendor: :h3c))
    fleet = Object.new
    fleet.define_singleton_method(:devices) { |**| [device] }
    fleet.define_singleton_method(:inventory_status) do
      { source: :stale_cache, refresh_error_code: :request_failed, write_error_type: "IOError" }
    end
    N::CLI::Credentials.stub(:resolve, [Object.new, ->(*) { flunk "preview connected" }]) do
      N::Fleet.stub(:new, fleet) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--inventory-only", "--json", "--quiet"], env: {}, output: output, error: error).run
        assert_equal 0, status
      end
    end
    assert_includes error.string, "清单刷新失败，使用历史缓存（request_failed）"
    assert_includes error.string, "清单缓存写入失败（IOError）"
    assert_equal 1, JSON.parse(output.string).fetch("ready")
  end

  def test_existing_ap_description_is_preserved_through_the_configured_cli_policy
    fixture = TopologyFixture.new(:h3c, neighbor: "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 Smartrate-Ethernet1/0/1 room_01\n")
    fixture.description = "TO_AP-room_01_SE1/0/1"
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      File.write(path, { "topology" => { "neighbor_name_prefixes" => ["AP-"] } }.to_yaml)
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "vendor" => "H3C" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--plan", "--json", "--quiet"], env: {}, default_config: path, default_directory: root,
                                    connector_factory: ->(*) { fixture.device }, output: output, error: error).run
        assert_equal 0, status, error.string
      end
      device = JSON.parse(output.string).fetch("devices").first
      assert_equal 0, device.fetch("changes")
      assert_equal "matches", device.fetch("neighbors").first.fetch("status")
      assert_empty device.fetch("commands")
      refute device.key?("script_file")
      assert File.file?(device.fetch("device_report"))
      assert_equal "TO_AP-room_01_SE1/0/1", fixture.description
      refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:enter) })
    end
  ensure
    fixture&.close
  end

  def test_commands_are_exported_per_device_and_referenced_by_plan_and_reports
    fixture = TopologyFixture.new(:h3c)
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "name" => "edge-01", "vendor" => "H3C" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--plan", "--json", "--quiet"], env: {}, default_directory: root,
                                    connector_factory: ->(*) { fixture.device }, output: output, error: error).run
        assert_equal 1, status, error.string
      end
      summary = JSON.parse(output.string)
      item = summary.fetch("devices").first
      script = item.fetch("script_file")
      assert_equal "edge-01-192.0.2.1.cfg", File.basename(script)
      assert_equal item.fetch("commands").join("\n") + "\n", File.read(script)
      assert_equal Digest::SHA256.file(script).hexdigest, item.fetch("script_sha256")
      assert_equal 0o600, File.stat(script).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(script)).mode & 0o777
      assert_equal "edge-01-192.0.2.1.txt", File.basename(item.fetch("device_report"))
      assert_includes File.read(item.fetch("device_report")), "edge-01（192.0.2.1）"
      plan = JSON.parse(File.read(File.join(summary.fetch("directory"), "plan.json"))).fetch("devices").first
      assert_equal script, plan.fetch("script_file")
      assert_equal "edge-01", plan.fetch("name")
      assert_includes File.read(File.join(summary.fetch("directory"), "summary.txt")), script
      refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:enter) })
    end
  ensure
    fixture&.close
  end

  def test_script_write_failure_prevents_apply_and_keeps_a_failed_summary
    fixture = TopologyFixture.new(:h3c)
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "name" => "edge", "vendor" => "H3C" }])
      writer = C::Storage::AtomicFile.method(:write)
      failing = lambda do |path, *args|
        raise IOError, "private export failure" if path.end_with?(".cfg")

        writer.call(path, *args)
      end
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        C::Storage::AtomicFile.stub(:write, failing) do
          status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--apply", "--quiet"], env: {}, default_directory: root,
                                      connector_factory: ->(*) { fixture.device }, output: StringIO.new, error: StringIO.new).run
          assert_equal 2, status
        end
      end
      report = JSON.parse(File.read(Dir.glob(File.join(root, "*", "summary.json")).fetch(0)))
      assert_equal false, report.fetch("success")
      assert_equal "IOError", report.fetch("orchestration_error_type")
      refute(fixture.observed.any? { |command, _| command == fixture.sample.fetch(:enter) })
    end
  ensure
    fixture&.close
  end

  def test_default_result_is_a_compact_chinese_summary_with_explicit_pending_reasons
    fixture = TopologyFixture.new(:h3c, neighbor: "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 000f-e25d-ee91 -\n")
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "name" => "edge", "vendor" => "H3C" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: ["--plan"], env: {}, default_directory: root,
                                    connector_factory: ->(*) { fixture.device }, output: output, error: error).run
        assert_equal 1, status
      end
      assert_includes output.string, "采集完成 1 台"
      assert_includes output.string, "失败 0 台"
      assert_includes output.string, "待核实 1 个"
      assert_includes output.string, "邻居未提供名称 1 个接口"
      assert_includes output.string, "存在待修正或待核实项"
      assert output.string.lines.size <= 10
      refute_includes output.string + error.string, "unverified"
      refute_includes output.string, "192.0.2.1\t"
      assert_includes error.string, "含待核实接口 1 台"
      report = JSON.parse(File.read(Dir.glob(File.join(root, "*", "summary.json")).fetch(0)))
      assert_equal "unverified", report.fetch("devices").first.fetch("status")
      assert_equal 0, report.fetch("statistics").fetch("failed")
    end
  ensure
    fixture&.close
  end

  def test_shared_configuration_from_nc_config_is_visible_and_keeps_ap_descriptions
    fixture = TopologyFixture.new(:h3c, neighbor: "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 Smartrate-Ethernet1/0/1 room_01\n")
    fixture.description = "TO_AP-room_01_SE1/0/1"
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      File.write(path, { "backup" => { "parallel" => 50 }, "topology" => { "neighbor_name_prefixes" => ["AP-"] } }.to_yaml)
      inventory = Struct.new(:devices).new([{ "ip" => fixture.device.host, "vendor" => "H3C" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(configuration_options: { directories: [] }, argv: [], env: { "NC_CONFIG" => path },
                                    default_config: File.join(root, "topology.yml"), default_directory: root,
                                    connector_factory: ->(*) { fixture.device }, output: output, error: error).run
        assert_equal 0, status, error.string
      end
      assert_includes error.string, "配置：#{path}"
      assert_includes output.string, "无需修改 1 台"
      refute File.exist?(File.join(root, "topology.yml"))
      assert_empty Dir.glob(File.join(root, "*", "scripts", "*.cfg"))
    end
  ensure
    fixture&.close
  end

  private

  def audit_factory(completed, interrupt: false)
    lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:interfaces) { self }
        connector.define_singleton_method(:audit) do |**_options, &_format|
          completed << :audit
          raise Interrupt if interrupt

          plan = C::Interfaces::Plan.new(host: device.host, vendor: device.vendor, evidence: {}, changes: [], commands: [])
          C::Interfaces::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false)
        end
        connector.define_singleton_method(:close) { completed << :close }
      end
    end
  end

end
