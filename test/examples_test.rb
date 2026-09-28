# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "rbconfig"

class ConnectorExamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_empty_local_backup_does_not_report_success
    with_example("backup.rb", []) do |output, error, status, directory|
      assert_equal 1, status.exitstatus, error
      refute JSON.parse(output.lines.last).fetch("tasks_succeeded")
      summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      assert_equal "no_devices", summary.fetch("status")
    end
  end

  def test_tftp_report_keeps_invalid_inventory_devices_without_crashing
    with_example("backup_tftp.rb", [{ "ip" => "invalid", "vendor" => "H3C" }]) do |output, error, status, directory|
      assert_equal 1, status.exitstatus, error
      assert_empty error
      refute JSON.parse(output.lines.last).fetch("success")
      summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      item = summary.fetch("devices").first
      assert_equal "invalid_address", item.fetch("status")
      assert_nil item.fetch("remote_path")
      assert_nil item["session_log"]
    end
  end

  def test_tftp_unknown_actual_path_does_not_verify_the_planned_file_or_probe_the_server
    Dir.mktmpdir do |root|
      planned = File.join(root, "hillstone-192.0.2.1.dat")
      File.write(planned, "unrelated backup")
      File.utime(Time.now + 60, Time.now + 60, planned)
      [root, nil].each do |local_root|
        with_example("backup_tftp.rb", [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }],
                     preload_code: tftp_preload("../unsafe.dat"),
                     extra_env: { "TFTP_ROOT" => local_root, "NC_DEVICE_USERNAME" => "audit" }) do |output, error, status, directory|
          assert_equal 1, status.exitstatus, error
          assert_empty error
          refute JSON.parse(output.lines.last).fetch("success")
          summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
          item = summary.fetch("devices").first
          assert_equal "reported_with_error", item.fetch("status")
          assert_equal "transfer_path_unconfirmed", item.fetch("error_code")
          assert_nil item.fetch("remote_path")
          refute item.fetch("server_file_verified")
          %w[bytes sha256 server_sha256].each { |key| assert_nil item.fetch(key) }
        end
      end
    end
  end

  def test_tftp_path_mismatch_verifies_only_the_confirmed_actual_file
    Dir.mktmpdir do |root|
      actual = File.join(root, "actual.dat")
      File.write(actual, "confirmed backup")
      File.utime(Time.now + 60, Time.now + 60, actual)
      with_example("backup_tftp.rb", [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }],
                   preload_code: tftp_preload("actual.dat"),
                   extra_env: { "TFTP_ROOT" => root, "NC_DEVICE_USERNAME" => "audit" }) do |output, error, status, directory|
        assert_equal 1, status.exitstatus, error
        assert_empty error
        refute JSON.parse(output.lines.last).fetch("success")
        summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
        item = summary.fetch("devices").first
        assert_equal "reported_with_error", item.fetch("status")
        assert_equal "transfer_path_mismatch", item.fetch("error_code")
        assert_equal "actual.dat", item.fetch("remote_path")
        assert item.fetch("server_file_verified")
        assert_equal "confirmed backup", File.read(item.fetch("local_file"))
        assert_match(%r{/tftp/unnamed-192\.0\.2\.1\.dat\z}, item.fetch("local_file"))
        assert_equal "confirmed backup", File.read(item.fetch("server_archive_file"))
        assert_match(%r{/archive/\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d{2})?/unnamed-192\.0\.2\.1\.dat\z},
                     item.fetch("server_archive_file"))
        assert_equal File.size(actual), item.fetch("bytes")
        assert_equal "server_verified", item.fetch("verification")
        assert_equal Digest::SHA256.file(actual).hexdigest, item.fetch("server_sha256")
      end
    end
  end

  def test_local_backup_loads_project_dotenv_and_preserves_process_overrides
    [{}, { "NC_DEVICE_USERNAME" => "override", "NC_DEVICE_PASSWORD" => "override-password" }].each do |overrides|
      expected = overrides.empty? ? ["fixture-user", "fixture-password"] : overrides.values
      preload = <<~RUBY
        require #{File.join(ROOT, "test/support/fake_transport").inspect}
        Net::Connector::Netdisco::Fleet.prepend(Module.new do
          def initialize(**options)
            factory = lambda do |device, settings|
              raise "wrong credential source" unless settings.values_at(:username, :password) == #{expected.inspect}
              device.build_connector(**settings, transport: ConnectorFake.new("<device>", "sysname fixture\\n<device>"))
            end
            super(**options, connector_factory: factory)
          end
        end)
      RUBY
      dotenv = "NC_DEVICE_USERNAME=fixture-user\nNC_DEVICE_PASSWORD=fixture-password\n"
      with_example("backup.rb", [{ "ip" => "192.0.2.1", "vendor" => "H3C" }],
                   preload_code: preload, extra_env: overrides.merge("NC_PROGRESS" => "1"), dotenv: dotenv,
                   config: "inventory:\n  include_hosts: [192.0.2.1]\nbackup:\n  concurrency: 2\n") do |output, error, status, _directory|
        assert status.success?, error
        assert JSON.parse(output.lines.last).fetch("tasks_succeeded")
        assert_equal 1, JSON.parse(output.lines.last).fetch("counts").fetch("backed_up")
        refute_includes output + error, "fixture-password"
        assert_includes error, "登录成功"
        assert_includes error, "[1/1 100% 执行中 0]"
        assert_equal 2, output.lines.size
        directory = JSON.parse(output.lines.last).fetch("directory")
        assert_match(/\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d+)?\z/, File.basename(directory))
        assert File.file?(File.join(directory, "unnamed-192.0.2.1.txt"))
        text = File.read(File.join(directory, "summary.txt"))
        assert_includes text, "成功：1"
        assert_includes text, "+08:00"
        refute_includes text, "fixture-password"
        assert_equal 0o600, File.stat(File.join(directory, "summary.txt")).mode & 0o777
      end
    end
  end

  def test_default_selects_all_devices_and_sample_is_explicit
    rows = 7.times.map { |i| { "ip" => "192.0.2.#{i + 1}", "vendor" => "H3C" } }
    [[[], 7], [["--sample", "2"], 2]].each do |arguments, count|
      with_example("backup.rb", rows, arguments: ["--json", *arguments]) do |output, error, _status, directory|
        assert_empty error
        assert_equal count, JSON.parse(output.lines.first).fetch("plan").fetch("selected").size
        assert File.file?(Dir[File.join(directory, "backups/*/plan.json")].fetch(0))
      end
    end
  end

  def test_default_output_is_human_readable_without_json_or_command_spam
    with_example("backup.rb", [], extra_env: { "NC_PROGRESS" => "1" }, arguments: []) do |output, error, status, _directory|
      assert_equal 1, status.exitstatus
      assert_empty output
      assert_includes error, "本次 0 台"
      assert_includes error, "批次结束"
      assert_includes error, "summary.txt"
    end
  end

  def test_command_line_credentials_and_concurrency_override_environment_and_yaml
    preload = <<~RUBY
      require #{File.join(ROOT, "test/support/fake_transport").inspect}
      Net::Connector::Netdisco::Fleet.prepend(Module.new do
        def initialize(**options)
          raise "wrong concurrency" unless options.fetch(:settings).concurrency == 7
          raise "wrong key policy" unless options.fetch(:settings).connection_options[:host_key_policy] == :accept_new
          factory = lambda do |device, settings|
            raise "wrong credentials" unless settings.values_at(:username, :password) == ["cli-user", "cli-secret"]
            device.build_connector(**settings, transport: ConnectorFake.new("<device>", "sysname fixture\n<device>"))
          end
          super(**options, connector_factory: factory)
        end
      end)
    RUBY
    env = { "NC_CONCURRENCY" => "2", "NC_H3C_USERNAME" => "vendor-user", "NC_H3C_PASSWORD" => "vendor-secret", "NC_HOST_KEY_POLICY" => "strict" }
    with_example("backup.rb", [{ "ip" => "192.0.2.1", "vendor" => "H3C" }],
                 preload_code: preload, extra_env: env, config: "backup:\n  concurrency: 3\n",
                 arguments: %w[--json --concurrency 7 --username cli-user --password cli-secret --host-key-policy accept_new]) do |output, error, status, _directory|
      assert status.success?, error
      assert JSON.parse(output.lines.last).fetch("tasks_succeeded")
      refute_includes output + error, "cli-secret"
      refute_includes output + error, "vendor-secret"
    end
  end

  def test_bad_options_fail_before_inventory_without_echoing_secrets
    [%w[--concurrency 0], %w[--concurrency 51], %w[--concurrency private-secret],
     %w[--stdin-credentials --password private-secret], %w[--ask-password]].each do |arguments|
      with_example("backup.rb", [], arguments: arguments) do |output, error, status, directory|
        refute status.success?
        assert_empty output
        refute_includes error, "private-secret"
        assert_empty Dir[File.join(directory, "backups/*")]
      end
    end
  end

  def test_command_line_environment_is_isolated_and_explicit_netdisco_login_overrides_api_key
    require_relative "../lib/net/connector/netdisco"
    env = { "NETDISCO_API_KEY" => "old-token", "NC_H3C_PASSWORD" => "old-device",
            "NC_H3C_ENABLE_PASSWORD" => "keep-enable" }
    options = { environment: { "NETDISCO_USERNAME" => "reader", "NETDISCO_PASSWORD" => "new-token",
                               "NETDISCO_URL" => "https://inventory.example", "NC_DEVICE_PASSWORD" => "new-device" } }
    result = Net::Connector::Netdisco::CLI::Options.environment(options, env: env)
    refute result.key?("NETDISCO_API_KEY")
    refute result.key?("NC_H3C_PASSWORD")
    assert_equal "keep-enable", result.fetch("NC_H3C_ENABLE_PASSWORD")
    assert_equal "new-device", result.fetch("NC_DEVICE_PASSWORD")
    assert_equal "old-device", env.fetch("NC_H3C_PASSWORD")
    assert_equal "old-token", env.fetch("NETDISCO_API_KEY")
  end

  def test_batch_directory_uses_utc_plus_eight_and_never_reuses_existing_directory
    require_relative "../lib/net/connector/netdisco"
    Dir.mktmpdir do |root|
      time = Time.utc(2026, 9, 28, 16, 1, 2)
      first = Net::Connector::Storage::BatchDirectory.create(root, time: time)
      second = Net::Connector::Storage::BatchDirectory.create(root, time: time)
      assert_equal "2026-09-29_00-01-02", File.basename(first)
      assert_equal "2026-09-29_00-01-02_01", File.basename(second)
      assert_equal 0o700, File.stat(first).mode & 0o777
    end
  end

  def test_backup_success_agrees_with_report_policy_when_inventory_is_incomplete
    preload = <<~RUBY
      require #{File.join(ROOT, "test/support/fake_transport").inspect}
      Net::Connector::Netdisco::Fleet.prepend(Module.new do
        def initialize(**options)
          factory = ->(device, settings) { device.build_connector(**settings, transport: ConnectorFake.new("<device>", "sysname fixture\\n<device>")) }
          super(**options, connector_factory: factory)
        end
      end)
    RUBY
    rows = [{ "ip" => "192.0.2.1", "vendor" => "H3C" }, { "ip" => "192.0.2.2", "vendor" => "unknown" }]
    with_example("backup.rb", rows, preload_code: preload, extra_env: { "NC_DEVICE_USERNAME" => "audit" }) do |output, error, status, directory|
      assert_equal 1, status.exitstatus, error
      document = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      refute document.fetch("policy_success")
      refute JSON.parse(output.lines.last).fetch("tasks_succeeded")
      assert_equal "selected", document.fetch("policy")
      assert(document.fetch("devices").all? { |item| item.key?("diagnostic") })
    end
  end

  def test_remote_tftp_upload_is_successful_but_explicitly_unverified
    with_example("backup_tftp.rb", [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }],
                 preload_code: tftp_preload("hillstone-192.0.2.1.dat"),
                 extra_env: { "NC_DEVICE_USERNAME" => "audit" }) do |output, error, status, directory|
      assert_equal 0, status.exitstatus, error
      assert JSON.parse(output.lines.last).fetch("success")
      document = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      assert_equal 1, document.fetch("verification").fetch("unverified")
      refute document.fetch("devices").first.fetch("server_file_verified")
    end
  end

  def test_text_report_failure_prevents_success_and_is_recorded_in_json
    preload = <<~RUBY
      class Net::Connector::Netdisco::Report::Text
        def self.write(**) = raise(IOError, "private-value")
      end
    RUBY
    with_example("backup.rb", [], preload_code: preload) do |output, error, status, directory|
      assert_equal 1, status.exitstatus, error
      document = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      assert_equal "IOError", document.fetch("report_error")
      refute JSON.parse(output.lines.last).fetch("tasks_succeeded")
      refute_includes output + error, "private-value"
    end
  end

  def test_custom_tftp_logs_are_reported_at_the_actual_location
    Dir.mktmpdir do |logs|
      with_example("backup_tftp.rb", [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }],
                   preload_code: tftp_preload("hillstone-192.0.2.1.dat"),
                   extra_env: { "NC_DEVICE_USERNAME" => "audit", "NC_LOG_DIRECTORY" => logs }) do |_output, error, status, directory|
        assert status.success?, error
        summary_path = Dir[File.join(directory, "backups/*/summary.json")].fetch(0)
        document = JSON.parse(File.read(summary_path))
        assert_equal File.join(logs, "192.0.2.1.log"), document.fetch("devices").first.fetch("session_log")
        assert File.file?(File.join(logs, "192.0.2.1.log"))
        out, err, process = Open3.capture3(RbConfig.ruby, File.join(ROOT, "examples/review_tftp.rb"), File.dirname(summary_path))
        assert process.success?, err
        assert_equal 1, JSON.parse(out).fetch("device_confirmed_uploads")
      end
    end
  end

  private

  def tftp_preload(actual_path)
    <<~RUBY
      require #{File.join(ROOT, "test/support/fake_transport").inspect}
      Net::Connector::Netdisco::Fleet.prepend(Module.new do
        def initialize(**options)
          factory = lambda do |device, settings|
            transport = ConnectorFake.new("fw#")
            transport.on_write = lambda do |bytes, _timeout|
              remote = #{actual_path.inspect} == "hillstone-192.0.2.1.dat" ? bytes.strip.split.last : #{actual_path.inspect}
              transport.events << "Export ok,target file name \#{remote}\\nfw#"
            end
            device.build_connector(**settings, transport: transport)
          end
          super(**options, connector_factory: factory)
        end
      end)
      module Open3
        def self.capture3(*) = raise("unexpected remote file probe")
      end
    RUBY
  end

  # Run real example entrypoints with an in-memory inventory and no network I/O.
  def with_example(name, rows, preload_code: "", extra_env: {}, dotenv: nil, config: nil, arguments: ["--json", "--verbose"])
    Dir.mktmpdir do |root|
      directory = File.join(root, "examples")
      FileUtils.mkdir_p(directory)
      File.write(File.join(root, ".env"), dotenv) if dotenv
      FileUtils.cp(File.join(ROOT, "examples", name), directory)
      FileUtils.cp(File.join(ROOT, "examples/boot.rb"), directory)
      preload = File.join(directory, "inventory.rb")
      File.write(preload, <<~RUBY)
        require "net/connector/netdisco"
        class Net::Connector::Netdisco::Client
          def devices = #{rows.inspect}
        end
        #{preload_code}
      RUBY
      env = ENV.keys.grep(/\A(?:NETDISCO_|NET_CONNECTOR_|NC_|TFTP_)/).to_h { |key| [key, nil] }
      env.merge!("NETDISCO_URL" => "https://inventory.example", "NETDISCO_API_KEY" => "test",
                 "TFTP_HOST" => "192.0.2.10", "NC_BACKUP_DIRECTORY" => File.join(directory, "backups"),
                 "NC_PROGRESS" => "0")
      if config
        path = File.join(root, "config.yml")
        File.write(path, config)
        env["NC_CONFIG"] = path
      end
      env.merge!(extra_env)
      output, error, status = Open3.capture3(env, RbConfig.ruby, "-I#{File.join(ROOT, "lib")}",
                                             "-r", preload, File.join(directory, name), *arguments)
      yield output, error, status, directory
    end
  end
end
