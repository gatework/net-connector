# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "json"

class ExampleEnvironmentTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GEMFILE = File.expand_path(ENV.fetch("BUNDLE_GEMFILE", File.join(ROOT, "Gemfile")))

  def test_explicit_host_overrides_environment_filter_and_topology_uses_shared_parallel_default
    data = settings(%w[--host 192.0.2.2], { "NC_INCLUDE_HOSTS" => "192.0.2.1", "NC_PARALLEL" => "7" })
    assert_equal ["192.0.2.2"], data.dig("inventory", "include_hosts")
    assert_equal 7, data.dig("topology", "parallel")
  end

  def test_cli_overrides_process_environment_and_process_environment_overrides_yaml
    Dir.mktmpdir do |root|
      path = File.join(root, "policy.yml")
      File.write(path, { "backup" => { "parallel" => 3, "directory" => File.join(root, "yaml") },
                         "netdisco" => { "url" => "https://yaml.example.invalid" },
                         "ssh" => { "host_key_policy" => "accept_new" },
                         "tftp" => { "server" => "192.0.2.20" } }.to_yaml)
      defaults = { "NC_PARALLEL" => "7", "NC_BACKUP_DIRECTORY" => File.join(root, "env"),
                   "ND_URL" => "https://env.example.invalid", "NC_HOST_KEY_POLICY" => "strict", "NC_TFTP_HOST" => "192.0.2.10" }
      data = settings(["--config", path], defaults)
      assert_equal 7, data.dig("backup", "parallel")
      assert_equal File.join(root, "env"), data.dig("backup", "directory")
      assert_equal "https://env.example.invalid", data.dig("netdisco", "url")
      assert_equal "strict", data.dig("ssh", "host_key_policy")
      assert_equal "192.0.2.10", data.dig("tftp", "server")
      data = settings(["--config", path, "--parallel", "2", "--directory", File.join(root, "cli")], defaults)
      assert_equal 2, data.dig("backup", "parallel")
      assert_equal File.join(root, "cli"), data.dig("backup", "directory")
    end
  end

  def test_environment_fills_missing_yaml_settings_without_exporting_credentials
    Dir.mktmpdir do |root|
      path = File.join(root, "policy.yml")
      File.write(path, {}.to_yaml)
      defaults = { "NC_PARALLEL" => "7", "NC_BACKUP_DIRECTORY" => File.join(root, "env"),
                   "NC_HOST_KEY_POLICY" => "strict", "NC_KNOWN_HOSTS" => File.join(root, "known_hosts"),
                   "ND_URL" => "https://env.example.invalid", "ND_USERNAME" => "reader", "ND_PASSWORD" => "private-fixture" }
      data = settings(["--config", path], defaults)
      assert_equal 7, data.dig("backup", "parallel")
      assert_equal File.join(root, "env"), data.dig("backup", "directory")
      assert_equal "strict", data.dig("ssh", "host_key_policy")
      assert_equal File.join(root, "known_hosts"), data.dig("ssh", "known_hosts")
      refute_includes JSON.generate(data), "private-fixture"
    end
  end

  def test_process_environment_overrides_yaml_null
    Dir.mktmpdir do |root|
      path = File.join(root, "policy.yml")
      File.write(path, { "ssh" => { "max_script_output_bytes" => nil } }.to_yaml)
      data = settings(["--config", path], { "NC_MAX_SCRIPT_OUTPUT_BYTES" => "64" })
      assert_equal 64, data.dig("ssh", "max_script_output_bytes")
    end
  end

  def test_backup_entry_keeps_environment_directory_when_yaml_does_not_set_one
    Dir.mktmpdir do |root|
      path = File.join(root, "policy.yml")
      File.write(path, {}.to_yaml)
      directory = File.join(root, "env-backups")
      script = <<~RUBY
        require "dotenv"
        def Dotenv.load(*) = {}
        ENV["NC_BACKUP_DIRECTORY"] = #{directory.inspect}
        ENV["NC_PARALLEL"] = "7"
        require "net/connector/netdisco"
        module Net::Connector::Netdisco::CLI::Credentials
          def self.resolve(settings, **)
            raise "entry lost environment directory" unless settings.backup_directory == #{directory.inspect}
            raise "entry lost environment parallel" unless settings.parallel == 7
            rows = [{ "ip" => "192.0.2.1", "vendor" => "H3C", "name" => "edge" }]
            [Struct.new(:devices).new(rows), ->(*) { raise "preview requested credentials" }]
          end
        end
        ARGV.replace(["--config", #{path.inspect}, "--inventory-only", "--json", "--quiet"])
        load #{File.join(ROOT, "examples/backup.rb").inspect}
      RUBY
      environment = ENV.keys.grep(/\A(?:NC_|ND_|NETDISCO_)/).to_h { |key| [key, nil] }
      environment.merge!("BUNDLE_GEMFILE" => GEMFILE, "HOME" => root, "XDG_CONFIG_HOME" => File.join(root, "config"))
      output, error, status = Open3.capture3(environment, RbConfig.ruby,
                                           "-rbundler/setup", "-e", script, chdir: root)
      assert status.success?, error
      assert_equal 1, JSON.parse(output).fetch("plan").fetch("selected").size
      refute File.exist?(directory)
    end
  end

  private

  def settings(argv, defaults)
    script = <<~RUBY
      require "net/connector/netdisco"
      require "json"
      options = Net::Connector::Netdisco::CLI::Options.parse(argv: #{argv.inspect})
      settings = Net::Connector::Netdisco::CLI::Options.settings(options, env: #{defaults.inspect}, configuration: Net::Connector::Netdisco::CLI::Options.configuration(options, env: #{defaults.inspect}, directories: []))
      puts JSON.generate(settings.snapshot(mode: :show_config).public_config)
    RUBY
    environment = { "BUNDLE_GEMFILE" => GEMFILE }
    output, error, status = Open3.capture3(environment, RbConfig.ruby, "-rbundler/setup", "-e", script, chdir: ROOT)
    assert status.success?, error
    JSON.parse(output)
  end
end
