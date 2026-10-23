# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "stringio"
require_relative "../lib/net/connector/netdisco"
require_relative "../lib/net/connector/netdisco/config/initializer"

class ConfigInitializerTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_noninteractive_creation_is_private_validated_and_never_overwrites
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      input = Object.new
      input.define_singleton_method(:gets) { raise "must not read stdin" }
      initializer = N::Config::Initializer.new(input: input, output: StringIO.new)
      document = { "backup" => { "parallel" => 4 } }
      assert_equal :created, initializer.create(path: path, document: document, interactive: false)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 4, N::Settings.from_file(path, env: {}).parallel
      assert_equal :exists, initializer.create(path: path, document: { "backup" => { "parallel" => 8 } }, interactive: true)
      assert_equal document, YAML.safe_load_file(path)
      assert_equal ["backup.yml"], Dir.children(root)
    end
  end

  def test_invalid_document_and_symlink_have_no_write_side_effect
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      initializer = N::Config::Initializer.new(input: StringIO.new, output: StringIO.new)
      assert_raises(ArgumentError) { initializer.create(path: path, document: { "password" => "private" }, interactive: false) }
      refute File.exist?(path)
      target = File.join(root, "target")
      File.write(target, "original")
      File.symlink(target, path)
      assert_raises(ArgumentError) { initializer.create(path: path, document: {}, interactive: false) }
      assert_equal "original", File.read(target)
    end
  end

  def test_interactive_eof_leaves_no_partial_file
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      initializer = N::Config::Initializer.new(input: StringIO.new("y\n"), output: StringIO.new)
      assert_raises(EOFError) { initializer.create(path: path, document: {}, interactive: true) }
      assert_empty Dir.children(root)
    end
  end

  def test_interactive_answers_are_validated_and_invalid_values_reprompt
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      answers = ["y", "http", "https://inventory.example.invalid", "192.0.2.1-20", "", "edge", "wlc", "S68*", "*spare", "contains", "glob", "h3c", "", "501", "8", "./backups", "192.0.2.10"]
      initializer = N::Config::Initializer.new(input: StringIO.new(answers.join("\n") + "\n"), output: StringIO.new)
      assert_equal :created, initializer.create(path: path, document: {}, interactive: true)
      settings = N::Settings.from_file(path, env: {})
      assert_equal ["S68*"], settings.public_config.fetch(:inventory).fetch(:include_models)
      assert_equal "glob", settings.public_config.fetch(:inventory).fetch(:model_match)
      assert_equal 8, settings.parallel
      assert_equal "192.0.2.10", settings.tftp_server
      assert_equal ["edge"], settings.public_config.fetch(:inventory).fetch(:include_names)
    end
  end

  def test_interactive_selector_empty_entries_reprompt_without_shifting_later_answers
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      answers = ["y", "http", "https://inventory.example.invalid", "192.0.2.1,", "192.0.2.2", "", "edge", "", "", "", "contains", "contains", "h3c", "", "4", "./backups"]
      initializer = N::Config::Initializer.new(input: StringIO.new(answers.join("\n") + "\n"), output: StringIO.new)
      assert_equal :created, initializer.create(path: path, document: {}, interactive: true, mode: :backup)
      inventory = N::Settings.from_file(path, env: {}).public_config.fetch(:inventory)
      assert_equal ["192.0.2.2"], inventory.fetch(:include_hosts)
      assert_empty inventory.fetch(:exclude_hosts)
      assert_equal ["edge"], inventory.fetch(:include_names)
    end
  end

  def test_shared_file_serialization_preserves_the_validated_interactive_answers
    Dir.mktmpdir do |root|
      path = File.join(root, "net-connector.yml")
      answers = ["y", "http", "https://inventory.example.invalid", "", "", "edge", "", "", "", "contains", "contains", "", "", "501", "8", "./reports"]
      output = StringIO.new
      initializer = N::Config::Initializer.new(input: StringIO.new(answers.join("\n") + "\n"), output: output)
      assert_equal :created, initializer.create(path: path, document: {}, interactive: true, mode: :backup)
      assert_equal ["backup"], YAML.safe_load_file(path).keys
      files = Net::Connector::Config.new(name: "backup", env: {}, directories: [], config: path).load
      settings = N::Settings.new(env: {}, defaults: N::Config.parse(files.data))
      assert_equal 8, settings.parallel
      assert_equal ["edge"], settings.public_config.fetch(:inventory).fetch(:include_names)
      assert_includes output.string, "Invalid value"
    end
  end

  def test_atomic_publication_race_keeps_the_competing_file_and_removes_temporary_files
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      original = File.method(:link)
      racing = lambda do |source, destination|
        File.write(destination, "competitor")
        original.call(source, destination)
      end
      initializer = N::Config::Initializer.new(input: StringIO.new, output: StringIO.new)
      status = File.stub(:link, racing) { initializer.create(path: path, document: {}, interactive: false) }
      assert_equal :exists, status
      assert_equal "competitor", File.read(path)
      assert_equal ["backup.yml"], Dir.children(root)
    end
  end

  def test_cancellation_before_publication_preserves_interrupt_and_leaves_no_files
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      original = Tempfile.method(:new)
      interruption = Interrupt.new("cancel initialization")
      wrapper = lambda do |*args|
        file = original.call(*args)
        file.define_singleton_method(:fsync) { raise interruption }
        file
      end
      initializer = N::Config::Initializer.new(input: StringIO.new, output: StringIO.new)
      error = Tempfile.stub(:new, wrapper) do
        assert_raises(Interrupt) { initializer.create(path: path, document: {}, interactive: false) }
      end
      assert_same interruption, error
      assert_empty Dir.children(root)
    end
  end

  def test_cancelled_interactive_input_leaves_no_half_configuration
    Dir.mktmpdir do |root|
      input = Object.new
      input.define_singleton_method(:gets) { |*| raise Interrupt }
      initializer = N::Config::Initializer.new(input: input, output: StringIO.new)
      assert_raises(Interrupt) { initializer.create(path: File.join(root, "backup.yml"), document: {}, interactive: true) }
      assert_empty Dir.children(root)
    end
  end

  def test_topology_questions_update_topology_policy_without_creating_backup_or_tftp_settings
    Dir.mktmpdir do |root|
      path = File.join(root, "topology.yml")
      answers = ["y", "http", "https://inventory.example.invalid", "", "", "edge", "", "", "", "contains", "contains", "", "", "6", "./topology"]
      initializer = N::Config::Initializer.new(input: StringIO.new(answers.join("\n") + "\n"), output: StringIO.new)
      document = { "topology" => { "mode" => "plan", "parallel" => 4 } }
      assert_equal :created, initializer.create(path: path, document: document, interactive: true)
      values = YAML.safe_load_file(path)
      assert_equal 6, values.fetch("topology").fetch("parallel")
      assert_equal "./topology", values.fetch("topology").fetch("directory")
      refute values.key?("backup")
      refute values.key?("tftp")
    end
  end

  def test_parent_sync_failure_keeps_complete_published_file_but_does_not_report_success
    Dir.mktmpdir do |root|
      path = File.join(root, "backup.yml")
      original = File.method(:open)
      failing = lambda do |name, *args, **options, &block|
        file = original.call(name, *args, **options, &block)
        file.define_singleton_method(:fsync) { raise IOError, "sync failed" } if name == File.realpath(root)
        file
      end
      initializer = N::Config::Initializer.new(input: StringIO.new, output: StringIO.new)
      File.stub(:open, failing) do
        assert_raises(IOError) { initializer.create(path: path, document: { "backup" => { "parallel" => 4 } }, interactive: false) }
      end
      assert_equal 4, YAML.safe_load_file(path).fetch("backup").fetch("parallel")
      assert_equal ["backup.yml"], Dir.children(root)
    end
  end

end
