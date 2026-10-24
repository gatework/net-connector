# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../lib/net/connector/config"

class ConfigTest < Minitest::Test
  Loader = Net::Connector::Config

  def setup
    @root = Dir.mktmpdir
    @low = File.join(@root, "low")
    @high = File.join(@root, "high")
    [@low, @high].each { |path| FileUtils.mkdir_p(path) }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_layers_merge_shared_common_namespace_then_native_files
    yaml(@low, "net-connector.yml", "common" => { "ssh" => { "port" => 22 }, "inventory" => { "include_names" => ["low"] } },
                                      "vxlan" => { "parallel" => 2, "devices" => ["one"] },
                                      "wireless" => "irrelevant malformed native config")
    yaml(@low, "vxlan.yml", "parallel" => 3, "devices" => ["two"])
    yaml(@high, "net-connector.yml", "vxlan" => { "parallel" => 4, "disabled" => false })
    explicit = yaml(@root, "explicit.yml", "parallel" => nil, "devices" => [])
    files = loader(config: explicit).load
    assert_equal({ "ssh" => { "port" => 22 }, "inventory" => { "include_names" => ["low"] },
                   "parallel" => nil, "devices" => [], "disabled" => false }, files.data)
    assert_equal({ "parallel" => nil, "devices" => [], "disabled" => false }, files.specific)
    assert_equal [File.join(@low, "net-connector.yml"), File.join(@low, "vxlan.yml"),
                  File.join(@high, "net-connector.yml"), explicit], files.config_files
    assert_equal explicit, files.sources.fetch("fields").fetch("/parallel")
    assert_equal File.join(@low, "net-connector.yml"), files.sources.fetch("fields").fetch("/ssh/port")
  end

  def test_relative_paths_are_resolved_before_each_layer_is_merged
    yaml(@low, "vxlan.yml", "ssh" => { "known_hosts" => "./known_hosts" }, "maps" => { "one" => "one.txt" })
    yaml(@high, "vxlan.yml", "parallel" => 3, "maps" => { "two" => "two.txt" })
    files = loader(path_fields: ["ssh.known_hosts", "maps.*"]).load
    assert_equal File.join(@low, "known_hosts"), files.data.dig("ssh", "known_hosts")
    assert_equal({ "one" => File.join(@low, "one.txt"), "two" => File.join(@high, "two.txt") }, files.data["maps"])
  end

  def test_explicit_shared_file_keeps_namespaces_paths_and_final_layer_precedence
    path = yaml(@low, "net-connector.yml", "common" => { "ssh" => { "known_hosts" => "keys" } },
                "vxlan" => { "parallel" => 7 }, "wireless" => "irrelevant malformed native config")
    yaml(@high, "vxlan.yml", "parallel" => 3)
    [{ config: path }, { env: { "VXLAN_CONFIG" => path } }].each do |selection|
      files = loader(**selection, path_fields: ["ssh.known_hosts"]).load
      assert_equal({ "ssh" => { "known_hosts" => File.join(@low, "keys") }, "parallel" => 7 }, files.data)
      assert_equal({ "parallel" => 7 }, files.specific)
      assert_equal [File.join(@high, "vxlan.yml"), path], files.config_files
      assert_equal path, files.sources.fetch("fields").fetch("/ssh/known_hosts")
      refute files.missing?
    end
  end

  def test_declared_yaml_paths_preserve_scheme_uris
    uri = "ssh://archive@example.test/var/tftp"
    yaml(@low, "vxlan.yml", "tftp" => { "verification_root" => uri, "verification_roots" => { "edge" => uri } })
    files = loader(path_fields: ["tftp.verification_root", "tftp.verification_roots.*"]).load
    assert_equal uri, files.data.dig("tftp", "verification_root")
    assert_equal uri, files.data.dig("tftp", "verification_roots", "edge")
  end

  def test_declared_environment_paths_preserve_scheme_uris
    uri = "ssh://archive@example.test/var/tftp"
    write(@low, ".env", "NC_TFTP_ROOT=#{uri}\n")
    files = loader(env_path_keys: ["NC_TFTP_ROOT"]).load_environment
    assert_equal uri, files.file_environment["NC_TFTP_ROOT"]
    assert_equal uri, files.environment["NC_TFTP_ROOT"]
    process = loader(env: { "NC_TFTP_ROOT" => uri }, env_path_keys: ["NC_TFTP_ROOT"]).load_environment
    assert_equal uri, process.process_environment["NC_TFTP_ROOT"]
    assert_equal uri, process.environment["NC_TFTP_ROOT"]
  end

  def test_declared_yaml_path_literals_are_scoped_by_field
    yaml(@low, "vxlan.yml", "netdisco" => { "db_sslrootcert" => "system", "cache_directory" => "system" })
    files = loader(path_fields: ["netdisco.db_sslrootcert", "netdisco.cache_directory"],
                   path_literals: { "netdisco.db_sslrootcert" => ["system"] }).load
    assert_equal "system", files.data.dig("netdisco", "db_sslrootcert")
    assert_equal File.join(@low, "system"), files.data.dig("netdisco", "cache_directory")
  end

  def test_yaml_paths_not_matching_declared_literals_still_resolve_from_source
    yaml(@low, "vxlan.yml", "netdisco" => { "db_sslrootcert" => "certs/root.pem" })
    files = loader(path_fields: ["netdisco.db_sslrootcert"],
                   path_literals: { "netdisco.db_sslrootcert" => ["system"] }).load
    assert_equal File.join(@low, "certs/root.pem"), files.data.dig("netdisco", "db_sslrootcert")
    yaml(@low, "vxlan.yml", "netdisco" => { "db_sslrootcert" => "system" })
    assert_equal File.join(@low, "system"), loader(path_fields: ["netdisco.db_sslrootcert"]).load.data.dig("netdisco", "db_sslrootcert")
  end

  def test_declared_environment_path_literals_preserve_file_and_process_values
    write(@low, ".env", "ND_DB_SSLROOTCERT=system\nOTHER_PATH=system\n")
    options = { env_path_keys: ["ND_DB_SSLROOTCERT", "OTHER_PATH"], path_literals: { "ND_DB_SSLROOTCERT" => ["system"] } }
    files = loader(**options).load_environment
    assert_equal "system", files.file_environment["ND_DB_SSLROOTCERT"]
    assert_equal File.join(@low, "system"), files.file_environment["OTHER_PATH"]
    process = loader(**options, env: { "ND_DB_SSLROOTCERT" => "system" }).load_environment
    assert_equal "system", process.process_environment["ND_DB_SSLROOTCERT"]
    assert_equal "system", process.environment["ND_DB_SSLROOTCERT"]
  end

  def test_environment_paths_not_matching_declared_literals_resolve_from_source
    write(@low, ".env", "ND_DB_SSLROOTCERT=certs/root.pem\n")
    options = { env_path_keys: ["ND_DB_SSLROOTCERT"], path_literals: { "ND_DB_SSLROOTCERT" => ["system"] } }
    assert_equal File.join(@low, "certs/root.pem"), loader(**options).load_environment.file_environment["ND_DB_SSLROOTCERT"]
    files = loader(**options, env: { "ND_DB_SSLROOTCERT" => "certs/process.pem" }).load_environment
    assert_equal File.join(@root, "certs/process.pem"), files.environment["ND_DB_SSLROOTCERT"]
  end

  def test_invalid_yaml_paths_report_the_field_without_the_value
    yaml(@low, "vxlan.yml", "netdisco" => { "db_sslrootcert" => "private-path\0.pem" })
    error = assert_raises(ArgumentError) { loader(path_fields: ["netdisco.db_sslrootcert"]).load }
    assert_includes error.message, "netdisco.db_sslrootcert"
    refute_includes error.message, "private-path"
    assert_nil error.cause
  end

  def test_invalid_environment_paths_report_the_key_without_the_value
    ["private-path\0.pem", "ssh://example.test/private-path\0.pem"].each do |value|
      error = assert_raises(ArgumentError) do
        loader(env: { "ND_DB_SSLROOTCERT" => value }, env_path_keys: ["ND_DB_SSLROOTCERT"])
      end
      assert_includes error.message, "ND_DB_SSLROOTCERT"
      refute_includes error.message, "private-path"
      assert_nil error.cause
    end
    write(@low, ".env", "ND_DB_SSLROOTCERT=private-path\0.pem\n")
    error = assert_raises(ArgumentError) { loader(env_path_keys: ["ND_DB_SSLROOTCERT"]).load_environment }
    assert_includes error.message, "ND_DB_SSLROOTCERT"
    refute_includes error.message, "private-path"
  end

  def test_environment_layers_do_not_mutate_input_and_process_values_win
    write(@low, ".env", "TOKEN=low\nLOW=low\nVXLAN_CONFIG=low.yml\nPATH_VALUE=relative\n")
    write(@high, ".env", "TOKEN=high\nHIGH=high\nVXLAN_CONFIG=../selected.yml\n")
    yaml(@root, "selected.yml", "parallel" => 7)
    env = { "TOKEN" => "process", "PROCESS" => "yes" }
    original = env.dup
    files = loader(env: env, env_path_keys: ["PATH_VALUE"]).load
    assert_equal original, env
    assert_equal "process", files.environment["TOKEN"]
    assert_equal "high", files.file_environment["TOKEN"]
    assert_equal "yes", files.process_environment["PROCESS"]
    assert_equal File.join(@low, "relative"), files.environment["PATH_VALUE"]
    assert_equal File.join(@root, "selected.yml"), files.config
    assert_equal 7, files.data["parallel"]
  end

  def test_explicit_environment_and_config_paths_are_last_and_relative_to_cwd
    write(@low, ".env", "TOKEN=low\n")
    explicit_env = write(@root, "custom.env", "TOKEN=explicit\nVXLAN_CONFIG=missing.yml\n")
    yaml(@root, "chosen.yml", "parallel" => 8)
    files = loader(config: "chosen.yml", env_file: "custom.env").load
    assert_equal "explicit", files.environment["TOKEN"]
    assert_equal explicit_env, files.env_file
    assert_equal File.join(@root, "chosen.yml"), files.config
    assert_equal 8, files.data["parallel"]
  end

  def test_process_selector_and_path_fields_use_starting_cwd
    yaml(@root, "chosen.yml", "parallel" => 8)
    files = loader(env: { "VXLAN_CONFIG" => "chosen.yml", "NC_PATH" => "known_hosts" }, env_path_keys: ["NC_PATH"]).load
    assert_equal File.join(@root, "chosen.yml"), files.config
    assert_equal File.join(@root, "known_hosts"), files.process_environment["NC_PATH"]
  end

  def test_environment_phase_does_not_read_yaml
    write(@low, "vxlan.yml", "bad: [yaml")
    files = loader.load_environment
    assert_empty files.config_files
    assert_raises(ArgumentError) { files.load }
  end

  def test_explicit_missing_files_fail_without_falling_back
    yaml(@low, "vxlan.yml", "parallel" => 3)
    error = assert_raises(ArgumentError) { loader(config: "missing.yml").load }
    assert_includes error.message, File.join(@root, "missing.yml")
    assert_raises(ArgumentError) { loader(env_file: "missing.env").load_environment }
    files = loader(config: "missing.yml", env_file: "missing.env").load(allow_missing: true)
    assert_equal 3, files.data["parallel"]
    assert_equal File.join(@root, "missing.yml"), files.init_config
    assert_equal File.join(@root, "missing.env"), files.init_env_file
  end

  def test_directories_are_absolute_unique_and_explicit_files_are_not_read_twice
    path = yaml(@low, "vxlan.yml", "devices" => ["one"])
    files = loader(directories: [@low, File.join(@low, "."), @high, @low], config: path).load
    assert_equal [path], files.config_files
    assert_equal ["one"], files.data["devices"]
  end

  def test_default_discovery_order_and_xdg_user_initialization
    home = File.join(@root, "home")
    xdg = File.join(@root, "xdg")
    script = File.join(@root, "bin", "vxlan")
    files = Loader.new(name: "vxlan", env: { "XDG_CONFIG_HOME" => xdg }, script: script, cwd: @root, home: home)
    assert_equal File.join(xdg, "net-connector", "vxlan.yml"), files.init_config
    assert_equal File.join(xdg, "net-connector", ".env"), files.init_env_file
    default = Loader.new(name: "vxlan", env: { "SUDO_USER" => "other" }, cwd: @root, home: home)
    assert_equal File.join(home, ".config", "net-connector", "vxlan.yml"), default.init_config
  end

  def test_empty_process_selector_does_not_mask_file_selector
    write(@low, ".env", "VXLAN_CONFIG=selected.yml\n")
    yaml(@low, "selected.yml", "parallel" => 5)
    files = loader(env: { "VXLAN_CONFIG" => "" }).load
    assert_equal File.join(@low, "selected.yml"), files.config
  end

  def test_results_and_all_nested_values_are_frozen_snapshots
    yaml(@low, "vxlan.yml", "devices" => [{ "host" => "one" }])
    env = { "TOKEN" => +"initial" }
    files = loader(env: env).load
    env["TOKEN"].replace("changed")
    yaml(@low, "vxlan.yml", "devices" => ["later"])
    assert_same files, files.load
    assert_equal "initial", files.environment["TOKEN"]
    assert_equal "one", files.data.dig("devices", 0, "host")
    [files.data, files.specific, files.environment, files.file_environment, files.process_environment,
     files.config_files, files.environment_files, files.sources, files.data["devices"], files.data.dig("devices", 0, "host")].each do |value|
      assert value.frozen?, value.inspect
    end
  end

  def test_shared_namespaces_and_common_keys_are_validated_without_validating_other_tools
    yaml(@low, "net-connector.yml", "unknown" => {})
    assert_raises(ArgumentError) { loader.load }
    yaml(@low, "net-connector.yml", "common" => { "parallel" => 5 })
    assert_raises(ArgumentError) { loader.load }
    yaml(@low, "net-connector.yml", "vxlan" => [], "wireless" => "invalid")
    assert_raises(ArgumentError) { loader.load }
    yaml(@low, "net-connector.yml", "wireless" => "invalid")
    assert loader.load.missing?
  end

  def test_irrelevant_tool_fields_are_not_validated_or_included
    yaml(@low, "net-connector.yml", "vxlan" => { "parallel" => 2 }, "wireless" => { 123 => "ignored" })
    assert_equal({ "parallel" => 2 }, loader.load.data)
  end

  def test_empty_mapping_preserves_existing_nested_field_provenance
    low = yaml(@low, "vxlan.yml", "ssh" => { "port" => 22 })
    yaml(@high, "vxlan.yml", "ssh" => {})
    files = loader.load
    assert_equal 22, files.data.dig("ssh", "port")
    assert_equal low, files.sources.fetch("fields").fetch("/ssh/port")
    refute files.sources.fetch("fields").key?("/ssh")
  end

  def test_native_configuration_must_be_a_mapping_and_reject_yaml_objects
    write(@low, "vxlan.yml", "- one\n- two\n")
    assert_raises(ArgumentError) { loader.load }
    write(@low, "vxlan.yml", "--- !ruby/object:Object {}\n")
    assert_raises(ArgumentError) { loader.load }
  end

  def test_duplicate_yaml_keys_cannot_silently_replace_device_scope
    ["devices: [{host: 192.0.2.1}]\ndevices: []\n",
     "devices:\n  - host: 192.0.2.1\n    'host': 192.0.2.2\n"].each do |body|
      write(@low, "vxlan.yml", body)
      error = assert_raises(ArgumentError) { loader.load }
      assert_includes error.message, "duplicate"
      assert_includes error.message, File.join(@low, "vxlan.yml")
      refute_includes error.message, "192.0.2.1"
    end
  end

  def test_multiple_yaml_documents_cannot_silently_discard_later_configuration
    write(@low, "vxlan.yml", "devices: [{host: 192.0.2.1}]\n---\ndevices: []\n")
    error = assert_raises(ArgumentError) { loader.load }
    assert_includes error.message, "single YAML document"
    assert_includes error.message, File.join(@low, "vxlan.yml")
  end

  def test_malformed_yaml_errors_do_not_retain_secret_contents_in_the_cause
    write(@low, "vxlan.yml", "private-fixture-value: [\n")
    error = assert_raises(ArgumentError) { loader.load }
    refute_includes error.full_message, "private-fixture-value"
    assert_nil error.cause
  end

  def test_common_only_is_missing_even_though_it_provides_defaults
    yaml(@low, "net-connector.yml", "common" => { "ssh" => { "port" => 22 } })
    files = loader.load
    assert files.missing?
    assert_equal 22, files.data.dig("ssh", "port")
    yaml(@high, "vxlan.yml", {})
    refute loader.load.missing?
  end

  def test_source_metadata_contains_paths_without_environment_values
    write(@low, ".env", "PASSWORD=do-not-display\n")
    files = loader.load
    assert_equal [File.join(@low, ".env")], files.sources["environment_files"]
    refute_includes files.sources.inspect, "do-not-display"
    assert_equal File.join(@low, ".env"), files.env_file
  end

  def test_dotenv_expansion_uses_injected_environment_and_not_the_real_process
    key = "NC_CONFIGURATION_TEST_SECRET"
    previous = ENV[key]
    ENV[key] = "real-value"
    write(@low, ".env", "TOKEN=$#{key}\nLOW=lower\n")
    write(@high, ".env", "EXPANDED=${LOW}\n")
    files = loader(env: { key => "injected" }).load_environment
    assert_equal "injected", files.environment["TOKEN"]
    assert_equal "lower", files.environment["EXPANDED"]
    assert_equal "", loader(env: {}).load_environment.environment["TOKEN"]
    assert_equal "real-value", ENV[key]
  ensure
    previous ? ENV[key] = previous : ENV.delete(key)
  end

  def test_bad_dotenv_and_command_substitution_are_rejected_without_exposing_contents
    write(@low, ".env", "this is not an assignment secret-value\n")
    error = assert_raises(ArgumentError) { loader.load_environment }
    refute_includes error.message, "secret-value"
    write(@low, ".env", "SECRET=$(touch #{@root}/executed)\n")
    assert_raises(ArgumentError) { loader.load_environment }
    refute File.exist?(File.join(@root, "executed"))
  end

  def test_directories_are_not_read_as_regular_configuration_or_environment_files
    FileUtils.mkdir_p(File.join(@low, "vxlan.yml"))
    assert_raises(ArgumentError) { loader.load }
    FileUtils.rm_rf(File.join(@low, "vxlan.yml"))
    FileUtils.mkdir_p(File.join(@low, ".env"))
    assert_raises(ArgumentError) { loader.load }
  end

  def test_require_and_empty_discovery_do_not_load_dotenv_or_connector_runtime
    code = <<~RUBY_CODE
      before = $LOADED_FEATURES.dup
      require "net/connector/config"
      Net::Connector::Config.new(name: "vxlan", env: {}, directories: []).load
      added = $LOADED_FEATURES - before
      abort added.inspect if added.any? { |path| path.match?(%r{/(dotenv|pg|expect|net/connector\\.rb)(/|\\.|$)}) }
    RUBY_CODE
    _, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", code)
    assert status.success?, error
  end

  def test_merge_is_non_destructive_and_replaces_arrays_false_and_nil
    left = { "nested" => { "left" => 1, "array" => [1], "enabled" => true }, "scalar" => "old" }
    right = { "nested" => { "right" => 2, "array" => [], "enabled" => false }, "scalar" => nil }
    merged = Loader.merge(left, right)
    assert_equal({ "nested" => { "left" => 1, "right" => 2, "array" => [], "enabled" => false }, "scalar" => nil }, merged)
    merged["nested"]["array"] << 9
    assert_empty right["nested"]["array"]
    assert_equal [1], left["nested"]["array"]
  end

  def test_dump_round_trips_native_values_and_paths_in_both_target_schemas
    %w[vxlan.yml net-connector.yml].each do |filename|
      path = File.join(@root, filename)
      document = { "devices" => [], "disabled" => false, "parallel" => nil, "ssh" => { "known_hosts" => "keys/hosts" } }
      File.write(path, Loader.dump(document, name: "vxlan", path: path))
      files = loader(directories: [], config: path, path_fields: ["ssh.known_hosts"]).load
      assert_equal({ "devices" => [], "disabled" => false, "parallel" => nil,
                     "ssh" => { "known_hosts" => File.join(@root, "keys/hosts") } }, files.data)
      assert_equal "keys/hosts", document.dig("ssh", "known_hosts")
      assert_equal path, files.sources.fetch("fields").fetch("/ssh/known_hosts")
    end
  end

  private

  def loader(**options)
    Loader.new(name: "vxlan", env: {}, script: File.join(@root, "bin", "vxlan"), cwd: @root,
               home: File.join(@root, "home"), directories: [@low, @high], **options)
  end

  def yaml(directory, name, data)
    write(directory, name, data.to_yaml)
  end

  def write(directory, name, contents)
    path = File.join(directory, name)
    File.write(path, contents)
    path
  end
end
