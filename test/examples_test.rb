# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
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

  private

  # Run real example entrypoints with an in-memory inventory and no device sessions.
  def with_example(name, rows)
    Dir.mktmpdir do |directory|
      FileUtils.cp(File.join(ROOT, "examples", name), directory)
      preload = File.join(directory, "inventory.rb")
      File.write(preload, <<~RUBY)
        require "net/connector/netdisco"
        class Net::Connector::Netdisco::Client
          def devices = #{rows.inspect}
        end
      RUBY
      env = ENV.keys.grep(/\A(?:NETDISCO_|NET_CONNECTOR_|TFTP_)/).to_h { |key| [key, nil] }
      env.merge!("NETDISCO_URL" => "https://inventory.example", "NETDISCO_API_KEY" => "test",
                 "TFTP_HOST" => "192.0.2.10", "NET_CONNECTOR_BACKUP_DIRECTORY" => directory)
      output, error, status = Open3.capture3(env, RbConfig.ruby, "-I#{File.join(ROOT, "lib")}",
                                             "-r", preload, File.join(directory, name))
      yield output, error, status, directory
    end
  end
end
