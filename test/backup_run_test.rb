# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

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
