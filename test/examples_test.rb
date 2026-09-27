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
    with_example("netdisco_backup.rb", []) do |output, error, status, directory|
      assert_equal 1, status.exitstatus, error
      refute JSON.parse(output.lines.last).fetch("tasks_succeeded")
      summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      assert_equal "no_devices", summary.fetch("status")
    end
  end

  def test_tftp_report_keeps_invalid_inventory_devices_without_crashing
    with_example("netdisco_tftp_backup.rb", [{ "ip" => "invalid", "vendor" => "H3C" }]) do |output, error, status, directory|
      assert_equal 1, status.exitstatus, error
      assert_empty error
      refute JSON.parse(output.lines.last).fetch("success")
      summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
      item = summary.fetch("outcomes").first
      assert_equal "invalid_address", item.fetch("status")
      assert_nil item.fetch("remote_path")
      assert_nil item.fetch("session_log")
    end
  end

  def test_tftp_unknown_actual_path_does_not_verify_the_planned_file_or_probe_the_server
    Dir.mktmpdir do |root|
      planned = File.join(root, "hillstone-192.0.2.1.dat")
      File.write(planned, "unrelated backup")
      File.utime(Time.now + 60, Time.now + 60, planned)
      [root, nil].each do |local_root|
        with_example("netdisco_tftp_backup.rb", [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }],
                     preload_code: tftp_preload("../unsafe.dat"),
                     extra_env: { "TFTP_ROOT" => local_root, "NET_CONNECTOR_DEVICE_USERNAME" => "audit" }) do |output, error, status, directory|
          assert_equal 1, status.exitstatus, error
          assert_empty error
          refute JSON.parse(output.lines.last).fetch("success")
          summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
          item = summary.fetch("outcomes").first
          assert_equal "reported_with_error", item.fetch("status")
          assert_equal "transfer_path_unconfirmed", item.fetch("error_code")
          assert_nil item.fetch("remote_path")
          refute item.fetch("server_file_verified")
          %w[local_file bytes sha256].each { |key| assert_nil item.fetch(key) }
        end
      end
    end
  end

  def test_tftp_path_mismatch_verifies_only_the_confirmed_actual_file
    Dir.mktmpdir do |root|
      actual = File.join(root, "actual.dat")
      File.write(actual, "confirmed backup")
      File.utime(Time.now + 60, Time.now + 60, actual)
      with_example("netdisco_tftp_backup.rb", [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }],
                   preload_code: tftp_preload("actual.dat"),
                   extra_env: { "TFTP_ROOT" => root, "NET_CONNECTOR_DEVICE_USERNAME" => "audit" }) do |output, error, status, directory|
        assert_equal 1, status.exitstatus, error
        assert_empty error
        refute JSON.parse(output.lines.last).fetch("success")
        summary = JSON.parse(File.read(Dir[File.join(directory, "backups/*/summary.json")].fetch(0)))
        item = summary.fetch("outcomes").first
        assert_equal "reported_with_error", item.fetch("status")
        assert_equal "transfer_path_mismatch", item.fetch("error_code")
        assert_equal "actual.dat", item.fetch("remote_path")
        assert item.fetch("server_file_verified")
        assert_equal actual, item.fetch("local_file")
        assert_equal File.size(actual), item.fetch("bytes")
        assert_equal Digest::SHA256.file(actual).hexdigest, item.fetch("sha256")
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
            transport = ConnectorFake.new("fw#", #{"Export ok,target file name #{actual_path}\nfw#".inspect})
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
  def with_example(name, rows, preload_code: "", extra_env: {})
    Dir.mktmpdir do |directory|
      FileUtils.cp(File.join(ROOT, "examples", name), directory)
      preload = File.join(directory, "inventory.rb")
      File.write(preload, <<~RUBY)
        require "net/connector/netdisco"
        class Net::Connector::Netdisco::Client
          def devices = #{rows.inspect}
        end
        #{preload_code}
      RUBY
      env = ENV.keys.grep(/\A(?:NETDISCO_|NET_CONNECTOR_|TFTP_)/).to_h { |key| [key, nil] }
      env.merge!("NETDISCO_URL" => "https://inventory.example", "NETDISCO_API_KEY" => "test",
                 "TFTP_HOST" => "192.0.2.10", "NET_CONNECTOR_BACKUP_DIRECTORY" => directory)
      env.merge!(extra_env)
      output, error, status = Open3.capture3(env, RbConfig.ruby, "-I#{File.join(ROOT, "lib")}",
                                             "-r", preload, File.join(directory, name))
      yield output, error, status, directory
    end
  end
end
