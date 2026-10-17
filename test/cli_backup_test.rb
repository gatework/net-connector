# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class CLIBackupTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def test_invalid_policy_does_not_create_a_batch_directory_or_read_credentials
    [{ "NC_PROTOCOL" => "invalid" }, { "NC_CONCURRENCY" => "0" },
     { "NC_HOST_KEY_POLICY" => "replace" }].each do |invalid|
      Dir.mktmpdir do |root|
        error = StringIO.new
        Netdisco::CLI::Credentials.stub(:resolve, ->(*) { flunk "invalid policy read credentials" }) do
          status = Netdisco::CLI::Backup.new(argv: [], env: invalid.merge("NC_BACKUP_DIRECTORY" => root),
                                           output: StringIO.new, error: error).run
          assert_equal 2, status, error.string
        end
        assert_empty Dir.children(root), invalid.inspect
      end
    end
  end

  def test_invalid_database_ca_path_is_rejected_before_directory_creation_or_credentials
    Dir.mktmpdir do |root|
      path = File.join(root, "config.yml")
      File.write(path, { "netdisco" => { "source" => "postgres", "query" => "SELECT ip FROM device",
                                        "db_sslrootcert" => "private-path\0suffix" } }.to_yaml)
      output, error = StringIO.new, StringIO.new
      Netdisco::CLI::Credentials.stub(:resolve, ->(*) { flunk "invalid database policy read credentials" }) do
        status = Netdisco::CLI::Backup.new(argv: ["--config", path, "--directory", root], env: {},
                                        output: output, error: error).run
        assert_equal 2, status
      end
      assert_equal ["config.yml"], Dir.children(root)
      assert_empty output.string
      assert_includes error.string, "netdisco.db_sslrootcert"
      refute_includes error.string, "private-path"
    end
  end

  def test_backup_persists_plan_events_and_reports_missing_credentials_without_leaking_them
    Dir.mktmpdir do |root|
      output, error = StringIO.new, StringIO.new
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      env = {}
      Netdisco::CLI::Credentials.stub(:resolve, [inventory, ->(_) { nil }]) do
        status = Netdisco::CLI::Backup.new(argv: ["--json", "--directory", root, "--no-progress"], env: env, input: StringIO.new,
                                        output: output, error: error).run
        assert_equal 1, status, error.string
      end

      preview, result = output.string.lines.map { |line| JSON.parse(line) }
      assert_equal "192.0.2.1", preview.fetch("plan").fetch("selected").first.fetch("host")
      directory = result.fetch("directory")
      assert_equal false, result.fetch("policy_success")
      assert_equal "missing_credentials", JSON.parse(File.read(File.join(directory, "events.jsonl"))).fetch("status")
      assert_equal 1, JSON.parse(File.read(File.join(directory, "plan.json"))).fetch("selected").size
      assert File.file?(File.join(directory, "summary.txt"))
      assert File.file?(result.fetch("report_location"))
      assert_empty error.string
    end
  end

  def config_path(root)
    path = File.join(root, "config.yml")
    File.write(path, "tftp:\n  server: 192.0.2.10\n")
    path
  end

  def test_tftp_requires_local_root_for_verified_policy_before_inventory
    Dir.mktmpdir do |root|
      error = StringIO.new
      status = Netdisco::CLI::Backup.new(mode: :tftp, argv: ["--success-policy", "verified", "--directory", root, "--config", config_path(root)],
                                       env: {},
                                       output: StringIO.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "verified policy requires a local TFTP directory"
      assert_equal ["config.yml"], Dir.children(root)
    end
  end

  def test_progress_failure_does_not_skip_events_reports_or_json_result
    Dir.mktmpdir do |root|
      output, error = StringIO.new, StringIO.new
      error.define_singleton_method(:tty?) { true }
      error.define_singleton_method(:write) do |text|
        raise IOError, "private terminal diagnostic" if text.include?("登录")

        super(text)
      end
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      Netdisco::CLI::Credentials.stub(:resolve, [inventory, ->(_) { nil }]) do
        status = Netdisco::CLI::Backup.new(argv: ["--json", "--directory", root], env: {},
                                        output: output, error: error).run
        assert_equal 1, status
      end
      preview, result = output.string.lines.map { |line| JSON.parse(line) }
      assert_equal 1, preview.fetch("plan").fetch("selected").size
      directory = result.fetch("directory")
      report = JSON.parse(File.read(result.fetch("report_location")))
      assert_equal [{ "host" => nil, "error_type" => "IOError" }], report.fetch("callback_errors")
      assert_equal "missing_credentials", JSON.parse(File.read(File.join(directory, "events.jsonl"))).fetch("status")
      assert File.file?(File.join(directory, "summary.txt"))
      refute_includes File.read(result.fetch("report_location")), "private terminal diagnostic"
    end
  end

  def test_final_display_failure_updates_saved_diagnostics_and_exit_status_without_repeating_devices
    ["批次结束", "报告：", "文本报告："].each do |trigger|
      Dir.mktmpdir do |root|
        output, error = StringIO.new, StringIO.new
        error.define_singleton_method(:write) do |text|
          raise IOError, "private terminal diagnostic" if text.include?(trigger)

          super(text)
        end
        inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Cisco", "os" => "ios" }])
        transport = ConnectorFake.new("router#", "router#", "hostname sample\nrouter#")
        original = Netdisco::Fleet.method(:new)
        factory = lambda do |**options|
          original.call(**options, connector_factory: ->(device, settings) { device.build_connector(**settings, transport: transport) })
        end
        Netdisco::Fleet.stub(:new, factory) do
          Netdisco::CLI::Credentials.stub(:resolve, [inventory, ->(_) { { username: "audit" } }]) do
            status = Netdisco::CLI::Backup.new(argv: ["--json", "--directory", root], env: {},
                                            output: output, error: error).run
            assert_equal 1, status, trigger
          end
        end
        result = JSON.parse(output.string.lines.last)
        report = JSON.parse(File.read(result.fetch("report_location")))
        assert_equal false, result.fetch("policy_success")
        assert_equal false, report.fetch("policy_success")
        assert_equal [{ "host" => nil, "error_type" => "IOError" }], report.fetch("callback_errors")
        assert_equal({ "backed_up" => 1 }, report.fetch("counts"))
        assert_equal ["terminal length 0\n", "show running-config\n"], transport.writes
        assert_equal 1, File.readlines(File.join(result.fetch("directory"), "events.jsonl")).size
        refute_includes File.read(result.fetch("report_location")), "private terminal diagnostic"
      end
    end
  end

  def test_stdin_confirmation_stops_before_writing_plan_or_running_devices
    Dir.mktmpdir do |root|
      output = StringIO.new
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      env = {}
      Netdisco::CLI::Credentials.stub(:resolve, [inventory, ->(_) { nil }]) do
        status = Netdisco::CLI::Backup.new(argv: ["--json", "--directory", root, "--no-progress", "--stdin-credentials"], env: env,
                                        input: StringIO.new("{}\nCANCEL\n"), output: output, error: StringIO.new).run
        assert_equal 1, status
      end
      assert_equal 1, output.string.lines.size
      refute File.exist?(File.join(Dir[File.join(root, "*")].fetch(0), "plan.json"))
    end
  end
end
