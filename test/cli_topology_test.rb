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
      status = N::CLI::Topology.new(argv: ["--help"], env: {}, default_config: File.join(root, "topology.yml"),
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
      status = N::CLI::Topology.new(argv: ["--inventory-only", "--name", "edge", "--json"], env: {}, output: output, error: StringIO.new).run
      assert_equal 0, status
    end
    assert_equal(["192.0.2.1"], JSON.parse(output.string).fetch("devices").map { |device| device.fetch("host") })
  end

  def test_apply_requires_and_persists_a_fresh_plan_before_device_application
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "name" => "edge01", "vendor" => "H3C" }])
      plan = C::Topology::Plan.new(host: "192.0.2.1", vendor: :h3c, evidence: {}, changes: [], commands: [])
      calls = []
      factory = lambda do |*|
        Object.new.tap do |connector|
          connector.define_singleton_method(:audit_interface_descriptions) { |**_options, &_format| calls << :plan; C::Topology::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false) }
          connector.define_singleton_method(:apply_interface_descriptions) do |value, confirmed:|
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
        status = N::CLI::Topology.new(argv: ["--apply", "--json", "--no-progress"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: [], env: {}, default_config: path, output: StringIO.new, error: StringIO.new).run
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
          connector.define_singleton_method(:audit_interface_descriptions) do |**_options, &_format|
            calls << device.host
            plan = C::Topology::Plan.new(host: device.host, vendor: device.vendor, evidence: {}, changes: [], commands: [])
            C::Topology::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false)
          end
          connector.define_singleton_method(:close) {}
        end
      end
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, resolver]) do
        status = N::CLI::Topology.new(argv: ["--plan", "--json"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: ["--apply", "--json", "--no-progress"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: ["--apply", "--json", "--no-progress"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: ["--discover", "--json"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: ["--plan", "--no-progress"], env: {}, default_directory: root,
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
          status = N::CLI::Topology.new(argv: ["--apply", "--no-progress"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: ["--discover", "--limit", "1", "--json", "--no-progress"], env: {}, default_directory: root,
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
        status = N::CLI::Topology.new(argv: ["--apply", "--stdin-credentials", "--no-progress"], env: {},
                                    default_directory: root, input: StringIO.new("DECLINE\n"),
                                    output: StringIO.new, error: StringIO.new).run
        assert_equal 1, status
      end
      assert_empty Dir.children(root)
    end
  end

  private

  def audit_factory(completed, interrupt: false)
    lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:audit_interface_descriptions) do |**_options, &_format|
          completed << :audit
          raise Interrupt if interrupt

          plan = C::Topology::Plan.new(host: device.host, vendor: device.vendor, evidence: {}, changes: [], commands: [])
          C::Topology::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false)
        end
        connector.define_singleton_method(:close) { completed << :close }
      end
    end
  end

end
