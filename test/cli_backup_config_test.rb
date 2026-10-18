# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class CLIBackupConfigTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_help_does_not_initialize_config_or_read_credentials
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      output = StringIO.new
      status = N::CLI::Backup.new(argv: ["--help"], env: {}, default_config: path, default_directory: root,
                                input: StringIO.new, output: output, error: StringIO.new).run
      assert_equal 0, status
      refute File.exist?(path)
      assert_includes output.string, "--plan"
    end
  end

  def test_missing_config_is_initialized_then_stops_before_inventory
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      N::CLI::Credentials.stub(:resolve, ->(*) { flunk "initialization queried inventory" }) do
        status = N::CLI::Backup.new(argv: ["--non-interactive"], env: {}, default_config: path, default_directory: root,
                                  input: StringIO.new, output: StringIO.new, error: StringIO.new).run
        assert_equal 0, status
      end
      assert File.file?(path)
      assert_equal ["backup.yml"], Dir.children(root)
    end
  end

  def test_plan_uses_default_config_and_filters_without_device_or_output_directory_creation
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      File.write(path, { "inventory" => { "include_names" => ["edge"] } }.to_yaml)
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "name" => "edge01", "vendor" => "H3C" },
                                          { "ip" => "192.0.2.2", "name" => "core01", "vendor" => "H3C" }])
      output = StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "plan requested device credentials" }]) do
        status = N::CLI::Backup.new(argv: ["--plan", "--json", "--no-progress"], env: {}, default_config: path,
                                  default_directory: File.join(root, "backups"), input: StringIO.new, output: output, error: StringIO.new).run
        assert_equal 0, status
      end
      assert_equal ["backup.yml"], Dir.children(root)
      data = JSON.parse(output.string)
      assert_equal(["192.0.2.1"], data.fetch("plan").fetch("selected").map { |item| item.fetch("host") })
    end
  end

  def test_tftp_inventory_preview_needs_no_server_or_native_tftp_capability
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Juniper", "os" => "Junos" }])
      output, error = StringIO.new, StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "inventory preview requested device credentials" }]) do
        status = N::CLI::Backup.new(mode: :tftp, argv: ["--inventory-only", "--json", "--no-progress"], env: {},
                                  default_directory: root, output: output, error: error).run
        assert_equal 0, status, error.string
      end
      assert_empty Dir.children(root)
      assert_equal(["192.0.2.1"], JSON.parse(output.string).fetch("plan").fetch("selected").map { |item| item.fetch("host") })
    end
  end

end
