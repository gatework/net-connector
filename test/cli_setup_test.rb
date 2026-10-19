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
        %W[boot.rb #{name}.rb].each { |file| FileUtils.cp(File.join(source, file), examples) }
        environment = ENV.keys.grep(/\A(?:NC_|ND_|NETDISCO_)/).to_h { |key| [key, nil] }
        environment.merge!("BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__),
                           "NC_CONFIG" => "", "ND_URL" => "https://inventory.example.invalid", "NC_PARALLEL" => "6")
        _output, error, status = Open3.capture3(environment, RbConfig.ruby, "-rbundler/setup",
                                              File.join(examples, "#{name}.rb"), "--init", "--non-interactive", chdir: root)
        assert status.success?, error
        config = File.join(examples, name == "topology" ? "topology.yml" : "backup.yml")
        document = YAML.safe_load_file(config)
        assert_equal 6, document.dig(name == "topology" ? "topology" : "backup", "parallel")
        assert_equal "https://inventory.example.invalid", document.dig("netdisco", "url")
        assert File.file?(File.join(root, ".env"))
        assert_equal %w[.env examples], Dir.children(root).sort
        if name == "topology"
          assert_equal File.join(File.realpath(examples), "topologys"), document.dig("topology", "directory")
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
                   default_config: path, default_env: environment, load_env: true, input: StringIO.new,
                   output: StringIO.new, error: error }
        N::CLI::Credentials.stub(:resolve, ->(*) { flunk "setup accessed credentials or inventory" }) do
          status = mode == :topology ? N::CLI::Topology.new(**kwargs).run : N::CLI::Backup.new(mode: mode, **kwargs).run
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

  def test_non_terminal_requires_explicit_init_and_does_not_consume_stdin
    [[], ["--non-interactive"], ["--stdin-credentials"]].each do |argv|
      Dir.mktmpdir do |root|
        input, error = StringIO.new("private credentials\nRUN\n"), StringIO.new
        status = N::CLI::Backup.new(argv: argv, default_config: File.join(root, "missing.yml"), env: {},
                                   input: input, output: StringIO.new, error: error).run
        assert_equal 2, status
        assert_includes error.string, "--init"
        assert_equal 0, input.pos
        assert_empty Dir.children(root)
      end
    end
  end

  def test_terminal_decline_required_yaml_creates_nothing
    Dir.mktmpdir do |root|
      error = Terminal.new
      status = N::CLI::Topology.new(argv: [], default_config: File.join(root, "topology.yml"),
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
      status = N::CLI::Topology.new(argv: [], default_config: path, default_env: env_path, env: {},
                                   input: Terminal.new("y\nn\nn\n"), output: Terminal.new, error: error).run
      assert_equal 0, status, error.string
      refute File.exist?(env_path)
      assert_equal "./topologys", YAML.safe_load_file(path).dig("topology", "directory")
    end
  end

  def test_existing_config_and_process_environment_work_without_dotenv
    Dir.mktmpdir do |root|
      path = File.join(root, "config.yml")
      File.write(path, "--- {}\n")
      options = { environment: { "NC_CONFIG" => path } }
      input = StringIO.new("untouched\n")
      setup = N::CLI::Setup.new(mode: :backup, options: options, env: { "ND_PASSWORD" => "from-process" },
                               env_path: File.join(root, ".env"), input: input, output: StringIO.new)
      refute setup.initialize_files?
      assert_equal 0, input.pos
      assert_equal ["config.yml"], Dir.children(root)
    end
  end

  def test_help_never_prompts_or_creates_environment
    Dir.mktmpdir do |root|
      %w[--help --help-all --examples].each do |flag|
        status = N::CLI::Backup.new(argv: [flag], env: {}, default_config: File.join(root, "config.yml"),
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
        status = N::CLI::Backup.new(argv: ["--init"], env: {}, default_config: path, default_env: env_path,
                                   input: StringIO.new, output: StringIO.new, error: StringIO.new).run
        assert_equal 0, status
      end
      assert_equal "--- {}\n", File.read(path)
      assert_equal "# preserved\n", File.read(env_path)
    end
  end

  def test_eof_at_creation_question_leaves_no_files
    Dir.mktmpdir do |root|
      status = N::CLI::Backup.new(argv: [], env: {}, default_config: File.join(root, "config.yml"),
                                 default_env: File.join(root, ".env"), input: Terminal.new("y\n"),
                                 output: Terminal.new, error: Terminal.new).run
      assert_equal 2, status
      assert_empty Dir.children(root)
    end
  end

  def test_invalid_environment_cannot_publish_configuration_or_secrets
    Dir.mktmpdir do |root|
      error = StringIO.new
      status = N::CLI::Backup.new(argv: ["--init"], env: { "NC_PARALLEL" => "secret-invalid-value" }, load_env: true,
                                 default_config: File.join(root, "config.yml"), default_env: File.join(root, ".env"),
                                 input: StringIO.new, output: StringIO.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "NC_PARALLEL"
      refute_includes error.string, "secret-invalid-value"
      assert_empty Dir.children(root)
    end
  end

  def test_symlink_is_rejected_without_overwrite
    Dir.mktmpdir do |root|
      target, path = File.join(root, "target"), File.join(root, "config.yml")
      File.write(target, "original")
      File.symlink(target, path)
      error = StringIO.new
      status = N::CLI::Backup.new(argv: ["--init"], env: {}, default_config: path,
                                 input: StringIO.new, output: StringIO.new, error: error).run
      assert_equal 2, status
      assert_includes error.string, "普通文件"
      assert_equal "original", File.read(target)
    end
  end

  def test_topology_cli_parallel_overrides_topology_environment_during_initialization
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      status = N::CLI::Topology.new(argv: ["--init", "-p", "9", "--directory", File.join(root, "chosen")],
                                   env: { "NC_TOPOLOGY_PARALLEL" => "30", "NC_TOPOLOGY_DIRECTORY" => File.join(root, "ignored") },
                                   load_env: true, default_config: path, input: StringIO.new,
                                   output: StringIO.new, error: StringIO.new).run
      assert_equal 0, status
      assert_equal 9, YAML.safe_load_file(path).dig("topology", "parallel")
      assert_equal File.join(root, "chosen"), YAML.safe_load_file(path).dig("topology", "directory")
    end
  end
end
