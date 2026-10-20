# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "open3"
require "fileutils"
require "rbconfig"
require_relative "../lib/net/connector/netdisco"

class CLISetupTest < Minitest::Test
  N = Net::Connector::Netdisco

  class Terminal < StringIO
    def tty? = true
  end

  def test_real_example_entries_detect_environment_and_initialize_in_an_empty_project
    %w[backup backup_tftp topology].each do |name|
      Dir.mktmpdir do |root|
        source = File.expand_path("../examples", __dir__)
        examples = File.join(root, "examples")
        FileUtils.mkdir_p(examples)
        File.symlink(File.expand_path("../lib", __dir__), File.join(root, "lib"))
        %W[boot.rb #{name}.rb].each { |file| FileUtils.cp(File.join(source, file), examples) }
        environment = ENV.keys.grep(/\A(?:NC_|ND_|NETDISCO_)/).to_h { |key| [key, nil] }
        environment.merge!("BUNDLE_GEMFILE" => File.expand_path(ENV.fetch("BUNDLE_GEMFILE", File.expand_path("../Gemfile", __dir__))),
                           "HOME" => root, "XDG_CONFIG_HOME" => File.join(root, "config"),
                           "NC_CONFIG" => "", "ND_URL" => "https://inventory.example.invalid", "NC_PARALLEL" => "6")
        _output, error, status = Open3.capture3(environment, RbConfig.ruby, "-rbundler/setup",
                                              File.join(examples, "#{name}.rb"), "--init", "--non-interactive", chdir: root)
        assert status.success?, error
        config = File.join(root, "config/net-connector", name == "topology" ? "topology.yml" : "backup.yml")
        document = YAML.safe_load_file(config)
        refute document.fetch(name == "topology" ? "topology" : "backup").key?("parallel")
        assert_equal "https://inventory.example.invalid", document.dig("netdisco", "url")
        assert File.file?(File.join(root, "config/net-connector/.env"))
        assert_equal %w[config examples lib], Dir.children(root).sort
        if name == "topology"
          assert_equal File.join(File.realpath(root), "topologys"), document.dig("topology", "directory")
          refute File.directory?(File.join(examples, "topologys"))
        end
      end
    end
  end

  def test_each_entry_initializes_private_files_without_inventory_or_passwords
    %i[backup tftp topology].each do |mode|
      Dir.mktmpdir do |root|
        path, environment = File.join(root, "config.yml"), File.join(root, ".env")
        error = StringIO.new
        env = { "NC_PARALLEL" => "20", "ND_URL" => "https://inventory.example.invalid", "ND_PASSWORD" => "secret-not-persisted",
                "NC_DEVICE_PASSWORD" => "device-not-persisted", "NC_TFTP_HOST" => "192.0.2.10" }
        kwargs = { argv: ["--init", "--non-interactive", "-p", "8", "--name", "edge"], env: env,
                   default_config: path, default_env: environment, input: StringIO.new,
                   output: StringIO.new, error: error }
        N::CLI::Credentials.stub(:resolve, ->(*) { flunk "setup accessed credentials or inventory" }) do
          status = mode == :topology ? N::CLI::Topology.new(configuration_options: { directories: [], home: root }, **kwargs).run : N::CLI::Backup.new(configuration_options: { directories: [], home: root }, mode: mode, **kwargs).run
          assert_equal 0, status, error.string
        end
        [path, environment].each do |file|
          assert_equal 0o600, File.stat(file).mode & 0o777
          refute_includes File.read(file), "not-persisted"
        end
        document = YAML.safe_load_file(path)
        assert_equal 8, document.fetch(mode == :topology ? "topology" : "backup").fetch("parallel")
        assert_equal ["edge"], document.dig("inventory", "include_names")
        assert_equal "https://inventory.example.invalid", document.dig("netdisco", "url")
        assert_equal "plan", document.dig("topology", "mode") if mode == :topology
        assert_equal "192.0.2.10", document.dig("tftp", "server") if mode == :tftp
        assert_equal %w[.env config.yml], Dir.children(root).sort
      end
    end
  end

  def test_each_entry_initializes_a_shared_file_that_reloads_with_explicit_values
    %i[backup tftp topology].each do |mode|
      Dir.mktmpdir do |root|
        path = File.join(root, "net-connector.yml")
        directory = File.join(root, "reports")
        error = StringIO.new
        kwargs = { configuration_options: { directories: [], home: root },
                   argv: ["--init", "--non-interactive", "--config", path, "-p", "8", "--directory", directory],
                   env: { "NC_PARALLEL" => "13" }, input: StringIO.new, output: StringIO.new, error: error }
        status = mode == :topology ? N::CLI::Topology.new(**kwargs).run : N::CLI::Backup.new(mode: mode, **kwargs).run
        assert_equal 0, status, error.string
        name = mode == :topology ? "topology" : "backup"
        assert_equal [name], YAML.safe_load_file(path).keys

        options = { environment: { "NC_CONFIG" => path } }
        files = N::CLI::Options.configuration(options, env: {}, mode: mode, directories: [], home: root)
        settings = N::CLI::Options.settings(options, mode: mode, configuration: files)
        assert_equal 8, mode == :topology ? settings.topology_options.parallel : settings.parallel
        assert_equal directory, files.data.dig(name, "directory")
        assert_equal [path], files.config_files
        assert_equal path, files.sources.fetch("fields").fetch("#{name}.parallel")
      end
    end
  end

  def test_initialization_keeps_shared_parallel_inherited_after_environment_changes
    %i[backup tftp topology].each do |mode|
      [nil, "13"].each do |initial_parallel|
        Dir.mktmpdir do |root|
          path, env_path = File.join(root, mode == :topology ? "topology.yml" : "backup.yml"), File.join(root, ".env")
          File.write(env_path, initial_parallel ? "NC_PARALLEL=#{initial_parallel}\n" : "")
          options = { environment: { "NC_CONFIG" => path }, env_file: env_path, init: true, interactive: false }
          configuration = N::CLI::Options.configuration(options, env: {}, mode: mode, directories: [], home: root)
          setup = N::CLI::Setup.new(mode: mode, options: options, configuration: configuration, input: StringIO.new, output: StringIO.new)
          assert setup.initialize_files?
          document = YAML.safe_load_file(path)
          refute document.fetch(mode == :topology ? "topology" : "backup").key?("parallel")

          File.write(env_path, "NC_PARALLEL=17\n")
          configuration = N::CLI::Options.configuration(options, env: {}, mode: mode, directories: [], home: root)
          settings = N::CLI::Options.settings(options, mode: mode, configuration: configuration)
          assert_equal 17, mode == :topology ? settings.topology_options.parallel : settings.parallel
        end
      end
    end
  end

  def test_interactive_parallel_displays_inheritance_and_only_persists_an_explicit_answer
    %i[backup topology].each do |mode|
      ["", "8"].each do |answer|
        Dir.mktmpdir do |root|
          path, env_path = File.join(root, mode == :topology ? "topology.yml" : "backup.yml"), File.join(root, ".env")
          File.write(env_path, "NC_PARALLEL=13\n")
          options = { environment: { "NC_CONFIG" => path }, env_file: env_path, init: true, interactive: true }
          configuration = N::CLI::Options.configuration(options, env: { "ND_URL" => "https://inventory.example.invalid" },
                                                       mode: mode, directories: [], home: root)
          answers = ["y", "", "", "", "", "", "", "", "", "", answer, ""]
          output = Terminal.new
          setup = N::CLI::Setup.new(mode: mode, options: options, configuration: configuration,
                                   input: Terminal.new(answers.join("\n") + "\n"), output: output)
          assert setup.initialize_files?
          section = YAML.safe_load_file(path).fetch(mode == :topology ? "topology" : "backup")
          if answer.empty?
            refute section.key?("parallel")
          else
            assert_equal 8, section.fetch("parallel")
          end
          assert_includes output.string, "[13]"
          assert_includes output.string, "留空继承"

          File.write(env_path, "NC_PARALLEL=17\n")
          configuration = N::CLI::Options.configuration(options, env: {}, mode: mode, directories: [], home: root)
          settings = N::CLI::Options.settings(options, mode: mode, configuration: configuration)
          assert_equal(answer.empty? ? 17 : 8, mode == :topology ? settings.topology_options.parallel : settings.parallel)
        end
      end
    end
  end

  def test_non_terminal_requires_explicit_init_and_does_not_consume_stdin
    [[], ["--non-interactive"], ["--stdin-credentials"]].each do |argv|
      Dir.mktmpdir do |root|
        input, error = StringIO.new("private credentials\nRUN\n"), StringIO.new
        status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: argv, default_config: File.join(root, "missing.yml"), env: {},
                                   input: input, output: StringIO.new, error: error).run
        assert_equal 2, status
        assert_includes error.string, "does not exist"
        assert_equal 0, input.pos
        assert_empty Dir.children(root)
      end
    end
  end

  def test_terminal_decline_required_yaml_creates_nothing
    Dir.mktmpdir do |root|
      error = Terminal.new
      status = N::CLI::Topology.new(configuration_options: { directories: [], home: root }, argv: ["--interactive"], default_config: File.join(root, "topology.yml"),
                                   default_env: File.join(root, ".env"), env: {}, input: Terminal.new("n\n"),
                                   output: Terminal.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "是否创建"
      assert_empty Dir.children(root)
    end
  end

  def test_terminal_accepts_yaml_declines_env_and_skips_customization
    Dir.mktmpdir do |root|
      path, env_path = File.join(root, "topology.yml"), File.join(root, ".env")
      error = Terminal.new
      status = N::CLI::Topology.new(configuration_options: { directories: [], home: root }, argv: ["--interactive"], default_config: path, default_env: env_path, env: {},
                                   input: Terminal.new("y\nn\nn\n"), output: Terminal.new, error: error).run
      assert_equal 0, status, error.string
      refute File.exist?(env_path)
      assert_equal File.expand_path("topologys"), YAML.safe_load_file(path).dig("topology", "directory")
    end
  end

  def test_existing_config_and_process_environment_work_without_dotenv
    Dir.mktmpdir do |root|
      path = File.join(root, "config.yml")
      File.write(path, "--- {}\n")
      options = { environment: { "NC_CONFIG" => path } }
      input = StringIO.new("untouched\n")
      configuration = N::CLI::Options.configuration(options, env: { "ND_PASSWORD" => "from-process" }, directories: [], home: root)
      setup = N::CLI::Setup.new(mode: :backup, options: options, configuration: configuration, input: input, output: StringIO.new)
      refute setup.initialize_files?
      assert_equal 0, input.pos
      assert_equal ["config.yml"], Dir.children(root)
    end
  end

  def test_help_never_prompts_or_creates_environment
    Dir.mktmpdir do |root|
      %w[--help --help-all --examples].each do |flag|
        status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: [flag], env: {}, default_config: File.join(root, "config.yml"),
                                   default_env: File.join(root, ".env"), input: Terminal.new, output: Terminal.new, error: Terminal.new).run
        assert_equal 0, status
        assert_empty Dir.children(root)
      end
    end
  end

  def test_init_preserves_existing_files_and_stops
    Dir.mktmpdir do |root|
      path, env_path = File.join(root, "config.yml"), File.join(root, ".env")
      File.write(path, "--- {}\n")
      File.write(env_path, "# preserved\n")
      N::CLI::Credentials.stub(:resolve, ->(*) { flunk "idempotent init started execution" }) do
        status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: ["--init"], env: {}, default_config: path, default_env: env_path,
                                   input: StringIO.new, output: StringIO.new, error: StringIO.new).run
        assert_equal 0, status
      end
      assert_equal "--- {}\n", File.read(path)
      assert_equal "# preserved\n", File.read(env_path)
    end
  end

  def test_eof_at_creation_question_leaves_no_files
    Dir.mktmpdir do |root|
      status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: ["--interactive"], env: {}, default_config: File.join(root, "config.yml"),
                                 default_env: File.join(root, ".env"), input: Terminal.new("y\n"),
                                 output: Terminal.new, error: Terminal.new).run
      assert_equal 2, status
      assert_empty Dir.children(root)
    end
  end

  def test_invalid_environment_cannot_publish_configuration_or_secrets
    Dir.mktmpdir do |root|
      error = StringIO.new
      status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: ["--init"], env: { "NC_PARALLEL" => "secret-invalid-value" },
                                 default_config: File.join(root, "config.yml"), default_env: File.join(root, ".env"),
                                 input: StringIO.new, output: StringIO.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "NC_PARALLEL"
      refute_includes error.string, "secret-invalid-value"
      assert_empty Dir.children(root)
    end
  end

  def test_invalid_selector_environment_cannot_publish_configuration
    Dir.mktmpdir do |root|
      status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: ["--init"],
                                 env: { "NC_INCLUDE_HOSTS" => "192.0.2.1," }, default_config: File.join(root, "backup.yml"),
                                 default_env: File.join(root, ".env"), input: StringIO.new, output: StringIO.new, error: StringIO.new).run
      assert_equal 2, status
      assert_empty Dir.children(root)
    end
  end

  def test_symlink_is_rejected_without_overwrite
    Dir.mktmpdir do |root|
      target, path = File.join(root, "target"), File.join(root, "config.yml")
      File.write(target, "original")
      File.symlink(target, path)
      error = StringIO.new
      status = N::CLI::Backup.new(configuration_options: { directories: [], home: root }, argv: ["--init"], env: {}, default_config: path,
                                 input: StringIO.new, output: StringIO.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "普通文件"
      assert_equal "original", File.read(target)
    end
  end

  def test_topology_cli_parallel_overrides_topology_environment_during_initialization
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      status = N::CLI::Topology.new(configuration_options: { directories: [], home: root }, argv: ["--init", "-p", "9", "--directory", File.join(root, "chosen")],
                                   env: { "NC_TOPOLOGY_PARALLEL" => "30", "NC_TOPOLOGY_DIRECTORY" => File.join(root, "ignored") },
                                   default_config: path, input: StringIO.new,
                                   output: StringIO.new, error: StringIO.new).run
      assert_equal 0, status
      assert_equal 9, YAML.safe_load_file(path).dig("topology", "parallel")
      assert_equal File.join(root, "chosen"), YAML.safe_load_file(path).dig("topology", "directory")
    end
  end
end
