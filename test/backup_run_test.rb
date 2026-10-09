# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class BackupRunTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def test_backup_persists_plan_events_and_reports_missing_credentials_without_leaking_them
    Dir.mktmpdir do |root|
      output, error = StringIO.new, StringIO.new
      client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      env = { "NC_BACKUP_DIRECTORY" => root, "NC_PROGRESS" => "0" }
      Netdisco::Connection.stub(:build, [client, ->(_) { nil }]) do
        status = Netdisco::BackupRun.new(argv: ["--json"], env: env, input: StringIO.new,
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

  def test_tftp_requires_local_root_for_verified_policy_before_inventory
    Dir.mktmpdir do |root|
      error = StringIO.new
      status = Netdisco::BackupRun.new(mode: :tftp, argv: ["--success-policy", "verified"],
                                       env: { "NC_BACKUP_DIRECTORY" => root, "TFTP_HOST" => "192.0.2.10" },
                                       output: StringIO.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "verified policy requires a local TFTP directory"
      assert_empty Dir.children(root)
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
      client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      Netdisco::Connection.stub(:build, [client, ->(_) { nil }]) do
        status = Netdisco::BackupRun.new(argv: ["--json"], env: { "NC_BACKUP_DIRECTORY" => root },
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
        client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Cisco", "os" => "ios" }])
        transport = ConnectorFake.new("router#", "router#", "hostname sample\nrouter#")
        original = Netdisco::Fleet.method(:new)
        factory = lambda do |**options|
          original.call(**options, connector_factory: ->(device, settings) { device.build_connector(**settings, transport: transport) })
        end
        Netdisco::Fleet.stub(:new, factory) do
          Netdisco::Connection.stub(:build, [client, ->(_) { { username: "audit" } }]) do
            status = Netdisco::BackupRun.new(argv: ["--json"], env: { "NC_BACKUP_DIRECTORY" => root },
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
      client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      env = { "NC_BACKUP_DIRECTORY" => root, "NC_PROGRESS" => "0" }
      Netdisco::Connection.stub(:build, [client, ->(_) { nil }]) do
        status = Netdisco::BackupRun.new(argv: ["--json", "--stdin-credentials"], env: env,
                                        input: StringIO.new("{}\nCANCEL\n"), output: output, error: StringIO.new).run
        assert_equal 1, status
      end
      assert_equal 1, output.string.lines.size
      refute File.exist?(File.join(Dir[File.join(root, "*")].fetch(0), "plan.json"))
    end
  end
end
