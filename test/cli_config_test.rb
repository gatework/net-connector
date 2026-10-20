# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/net/connector/netdisco"

class CLIConfigTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_cli_process_yaml_and_dotenv_precedence_and_source_relative_paths
    Dir.mktmpdir do |root|
      low, high = %w[low high].map { |name| File.join(root, name).tap { |path| Dir.mkdir(path) } }
      File.write(File.join(low, "net-connector.yml"), { "common" => { "ssh" => { "known_hosts" => "keys" } },
                                                                   "backup" => { "backup" => { "parallel" => 3, "directory" => "saved" } } }.to_yaml)
      File.write(File.join(high, ".env"), "NC_PARALLEL=4\nNC_DEVICE_PASSWORD=private-fixture\n")
      env = { "NC_PARALLEL" => "5" }
      options = N::CLI::Options.parse(argv: [])
      loader = N::CLI::Options.configuration(options, env: env, directories: [low, high])
      settings = N::CLI::Options.settings(options, env: env, configuration: loader)
      assert_equal 5, settings.parallel
      assert_equal File.join(low, "saved"), settings.backup_directory
      assert_equal File.join(low, "keys"), settings.connection_options.fetch(:known_hosts)
      assert_equal({ "NC_PARALLEL" => "5" }, env)
      options = N::CLI::Options.parse(argv: %w[--parallel 6])
      assert_equal 6, N::CLI::Options.settings(options, env: env, configuration: loader).parallel
      assert_equal 3, N::CLI::Options.settings({ environment: {} }, env: {},
        configuration: N::CLI::Options.configuration({ environment: {} }, env: {}, directories: [low, high])).parallel
    end
  end

  def test_show_config_from_each_entry_reports_sources_without_reading_inventory_or_secrets
    Dir.mktmpdir do |root|
      path, env_path = File.join(root, "custom.yml"), File.join(root, "custom.env")
      File.write(path, { "backup" => { "parallel" => 3 } }.to_yaml)
      File.write(env_path, "NC_DEVICE_PASSWORD=private-fixture\nNC_PARALLEL=4\n")
      [N::CLI, N::CLI::Backup, N::CLI::Topology].each do |entry|
        output, error = StringIO.new, StringIO.new
        N::CLI::Credentials.stub(:resolve, ->(*) { flunk "show-config read inventory" }) do
          status = entry.new(argv: ["--config", path, "--env-file", env_path, "--show-config"], env: {},
                             configuration_options: { directories: [] }, output: output, error: error).run
          assert_equal 0, status, error.string
        end
        data = JSON.parse(output.string)
        assert_equal 3, data.dig("backup", "parallel")
        assert_equal [path], data.dig("sources", "configuration_files")
        assert_equal [env_path], data.dig("sources", "environment_files")
        refute_includes output.string, "private-fixture"
      end
    end
  end

  def test_remote_tftp_roots_remain_uris_and_lower_priority_invalid_values_are_ignored
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      uri = "ssh://archive@files.example/srv/tftp"
      File.write(path, { "backup" => { "parallel" => 3 }, "tftp" => { "verification_root" => uri,
                         "verification_roots" => { "192.0.2.10" => uri } } }.to_yaml)
      File.write(File.join(root, ".env"), "NC_PARALLEL=invalid-overridden
")
      options = N::CLI::Options.parse(argv: %w[--parallel 6])
      loader = N::CLI::Options.configuration(options, env: { "NC_PARALLEL" => "invalid-overridden" }, directories: [root])
      settings = N::CLI::Options.settings(options, configuration: loader)
      assert_equal 6, settings.parallel
      assert_equal uri, settings.tftp_root
      assert_equal uri, settings.tftp_verification_roots.fetch("192.0.2.10")
    end
  end

  def test_shared_process_parallel_overrides_topology_yaml_and_cli_overrides_specific_process_parallel
    Dir.mktmpdir do |root|
      File.write(File.join(root, "topology.yml"), { "topology" => { "parallel" => 3 } }.to_yaml)
      options = N::CLI::Options.parse(argv: [], mode: :topology)
      loader = N::CLI::Options.configuration(options, env: { "NC_PARALLEL" => "5" }, mode: :topology, directories: [root])
      assert_equal 5, N::CLI::Options.settings(options, mode: :topology, configuration: loader).topology_options.parallel
      options = N::CLI::Options.parse(argv: %w[--parallel 6], mode: :topology)
      loader = N::CLI::Options.configuration(options, env: { "NC_TOPOLOGY_PARALLEL" => "7" }, mode: :topology, directories: [root])
      assert_equal 6, N::CLI::Options.settings(options, mode: :topology, configuration: loader).topology_options.parallel
    end
  end

  def test_environment_selectors_reject_blank_and_empty_entries_before_selection
    fields = {
      "NC_INCLUDE_HOSTS" => "192.0.2.1", "NC_EXCLUDE_HOSTS" => "192.0.2.1",
      "NC_INCLUDE_NAMES" => "edge", "NC_EXCLUDE_NAMES" => "edge",
      "NC_INCLUDE_VENDORS" => "h3c", "NC_EXCLUDE_VENDORS" => "h3c"
    }
    Dir.mktmpdir do |root|
      File.write(File.join(root, "backup.yml"), { "inventory" => { "include_hosts" => ["192.0.2.1"] } }.to_yaml)
      fields.each do |key, valid|
        [" ", ",", " , ", "#{valid},", "#{valid},,#{valid}"].each do |value|
          options = { environment: {} }
          loader = N::CLI::Options.configuration(options, env: { key => value }, directories: [root])
          error = assert_raises(ArgumentError) { N::CLI::Options.settings(options, configuration: loader).snapshot(mode: :inventory) }
          assert_includes error.message, key
          refute_includes error.message, value unless value.strip.empty? || value == ","
        end
      end
    end
  end

  def test_selector_overrides_keep_precedence_and_explicit_empty_lists
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      File.write(path, { "inventory" => { "include_hosts" => [] } }.to_yaml)
      File.write(File.join(root, ".env"), "NC_INCLUDE_HOSTS=' , '\n")
      options = { environment: {} }
      loader = N::CLI::Options.configuration(options, env: {}, directories: [root])
      assert_empty N::CLI::Options.settings(options, configuration: loader).public_config.dig(:inventory, :include_hosts)

      options = N::CLI::Options.parse(argv: %w[--hosts 192.0.2.2])
      loader = N::CLI::Options.configuration(options, env: { "NC_INCLUDE_HOSTS" => " , " }, directories: [root])
      assert_equal ["192.0.2.2"], N::CLI::Options.settings(options, configuration: loader).public_config.dig(:inventory, :include_hosts)

      File.write(path, "{}\n")
      options = { environment: {} }
      loader = N::CLI::Options.configuration(options, env: {}, directories: [root])
      assert_raises(ArgumentError) { N::CLI::Options.settings(options, configuration: loader).snapshot(mode: :inventory) }
    end
  end

  def test_explicit_shared_configuration_uses_the_same_schema_as_discovery
    Dir.mktmpdir do |root|
      path = File.join(root, "net-connector.yml")
      File.write(path, { "common" => { "inventory" => { "include_names" => ["edge"] } },
                        "backup" => { "backup" => { "parallel" => 7 } },
                        "topology" => { "topology" => { "parallel" => 9 } } }.to_yaml)
      %i[backup topology].each do |mode|
        [N::CLI::Options.parse(argv: ["--config", path], mode: mode), { environment: {} }].each do |options|
          loader = N::CLI::Options.configuration(options, env: { "NC_CONFIG" => path }, mode: mode, directories: [root])
          settings = N::CLI::Options.settings(options, mode: mode, configuration: loader)
          assert_equal ["edge"], settings.public_config.dig(:inventory, :include_names)
          assert_equal(mode == :topology ? 9 : 7, mode == :topology ? settings.topology_options.parallel : settings.parallel)
          assert_equal [path], loader.config_files
        end
      end
    end
  end

  def test_database_certificate_paths_follow_the_yaml_or_environment_source_directory
    Dir.mktmpdir do |root|
      source, startup = %w[source startup].map { |name| File.join(root, name).tap { |path| Dir.mkdir(path) } }
      yaml = File.join(source, "backup.yml")
      File.write(yaml, { "netdisco" => { "db_sslrootcert" => "ca.pem" } }.to_yaml)
      options = { environment: {} }
      loader = N::CLI::Options.configuration(options, env: {}, directories: [source], cwd: startup)
      assert_equal File.join(source, "ca.pem"), N::CLI::Options.settings(options, configuration: loader).database_options.fetch(:sslrootcert)
      File.delete(yaml)
      File.write(File.join(source, ".env"), "ND_DB_SSLROOTCERT=env-ca.pem\n")
      loader = N::CLI::Options.configuration(options, env: {}, directories: [source], cwd: startup)
      assert_equal File.join(source, "env-ca.pem"), N::CLI::Options.settings(options, configuration: loader).database_options.fetch(:sslrootcert)
      loader = N::CLI::Options.configuration(options, env: { "ND_DB_SSLROOTCERT" => "process-ca.pem" }, directories: [source], cwd: startup)
      assert_equal File.join(startup, "process-ca.pem"), N::CLI::Options.settings(options, configuration: loader).database_options.fetch(:sslrootcert)
    end
  end

  def test_database_system_trust_marker_is_preserved_for_yaml_and_environment_sources
    Dir.mktmpdir do |root|
      yaml = File.join(root, "backup.yml")
      File.write(yaml, { "netdisco" => { "db_sslrootcert" => "system" } }.to_yaml)
      options = { environment: {} }
      loader = N::CLI::Options.configuration(options, env: {}, directories: [root])
      assert_equal "system", N::CLI::Options.settings(options, configuration: loader).database_options.fetch(:sslrootcert)
      File.delete(yaml)
      File.write(File.join(root, ".env"), "ND_DB_SSLROOTCERT=system\n")
      loader = N::CLI::Options.configuration(options, env: {}, directories: [root])
      assert_equal "system", N::CLI::Options.settings(options, configuration: loader).database_options.fetch(:sslrootcert)
      loader = N::CLI::Options.configuration(options, env: { "ND_DB_SSLROOTCERT" => "system" }, directories: [root])
      assert_equal "system", N::CLI::Options.settings(options, configuration: loader).database_options.fetch(:sslrootcert)
    end
  end

  def test_init_uses_user_directory_without_creating_script_or_cwd_files
    Dir.mktmpdir do |root|
      output, error = StringIO.new, StringIO.new
      status = N::CLI.new(argv: %w[--init --non-interactive], env: {}, output: output, error: error,
                                 configuration_options: { directories: [], home: root }).run
      assert_equal 0, status, error.string
      directory = File.join(root, ".config/net-connector")
      assert_equal %w[.env backup.yml], Dir.children(directory).sort
      document = YAML.safe_load_file(File.join(directory, "backup.yml"))
      assert_equal File.expand_path("backups"), document.dig("backup", "directory")
    end
  end
end
