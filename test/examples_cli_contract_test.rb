# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"
require_relative "support/topology_fixture"

class ExampleCLIContractTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_backup_common_help_full_help_and_examples_have_distinct_useful_content
    %i[backup tftp].each do |mode|
      program = mode == :backup ? "backup.rb" : "backup_tftp.rb"
      common, full, examples = %w[--help --help-all --examples].map do |flag|
        output = StringIO.new
        N::CLI::Options.parse(argv: [flag], mode: mode, program: program, output: output)
        output.string
      end
      assert_includes common, "--plan"
      refute_includes common, "--stdin-credentials"
      assert_includes full, "--stdin-credentials"
      assert_includes full, "--exclude-hosts"
      assert_includes examples, "ruby #{program} --host 192.0.2.10"
      refute_includes examples, "--tftp-root" if mode == :backup
    end
  end

  def test_repeated_hosts_select_all_requested_devices_and_do_not_expand_inventory
    inventory = Struct.new(:devices).new((1..3).map { |i| { "ip" => "192.0.2.#{i}", "vendor" => "H3C" } })
    output, error = StringIO.new, StringIO.new
    N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "preview requested credentials" }]) do
      status = N::CLI::Backup.new(argv: %w[--plan --host 192.0.2.1 --host 192.0.2.3 --json --quiet],
                                env: {}, output: output, error: error).run
      assert_equal 0, status, error.string
    end
    assert_equal(%w[192.0.2.1 192.0.2.3], JSON.parse(output.string).fetch("plan").fetch("selected").map { |row| row.fetch("host") })
  end

  def test_tftp_plan_alias_is_inventory_only_without_server_or_output_directory
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "preview requested credentials" }]) do
        error = StringIO.new
        status = N::CLI::Backup.new(mode: :tftp, argv: %w[--plan --json --quiet], env: {}, default_directory: root,
                                  output: StringIO.new, error: error).run
        assert_equal 0, status, error.string
      end
      assert_empty Dir.children(root)
    end
  end

  def test_topology_full_help_only_advertises_supported_operations
    output = StringIO.new
    assert_equal 0, N::CLI::Topology.new(argv: ["--help-all"], env: {}, output: output, error: StringIO.new).run
    %w[--apply --description-format --full-port-names --lowercase-ports].each { |flag| assert_includes output.string, flag }
    %w[--sample --all --tftp-root --success-policy].each { |flag| refute_includes output.string, flag }
  end

  def test_topology_format_flags_change_the_persisted_plan_without_writing_the_device
    fixture = TopologyFixture.new(:cisco_ios)
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Cisco", "os" => "IOS" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        status = N::CLI::Topology.new(argv: %w[--plan --description-format Link_%{neighbor}_%{port} --full-port-names --lowercase-ports --json --quiet],
                                    env: {}, default_directory: root, connector_factory: ->(*) { fixture.device },
                                    output: output, error: error).run
        assert_equal 1, status, error.string
      end
      report = JSON.parse(output.string)
      assert_equal "Link_peer_gigabitethernet1/0/2", report.fetch("devices").first.fetch("neighbors").first.fetch("expected")
      assert_equal "original", fixture.description
      refute(fixture.observed.any? { |command, _| [fixture.sample[:enter], fixture.sample[:save]].include?(command) })
      assert File.file?(File.join(report.fetch("directory"), "plan.json"))
    end
  ensure
    fixture&.close
  end
end
