# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

# 必须以使用者实际的启动方式验证，不能在测试进程中预加载新模块来掩盖依赖错误。
class ExamplesEntryTest < Minitest::Test
  EXAMPLES = File.expand_path("../examples", __dir__)
  ROOT = File.dirname(EXAMPLES)

  def test_plain_entries_run_help_and_examples_from_the_examples_directory
    %w[backup.rb backup_tftp.rb topology.rb].each do |entry|
      %w[--help --examples].each do |option|
        output, error, status = launch(entry, option)
        assert status.success?, "#{entry} #{option}: #{error}"
        assert_includes output, entry == "topology.rb" ? "--apply" : "--plan"
        refute_match(/NameError|LoadError|net-connector-optimization/, error)
      end
    end
  end

  def test_bundled_entries_preserve_the_callers_dependency_selection
    %w[backup.rb backup_tftp.rb topology.rb].each do |entry|
      output, error, status = launch(entry, "--help", bundled: true)
      assert status.success?, "bundle exec ruby #{entry}: #{error}"
      assert_includes output, "--name"
      refute_match(/NameError|LoadError|net-connector-optimization/, error)
    end
  end

  def test_plain_boot_loads_its_own_library_without_reading_dotenv_or_changing_cwd
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".env"), "UNIFIED_BOOT_SENTINEL=from-file\n")
      script = <<~RUBY
        before = ENV.to_h
        directory = Dir.pwd
        require #{File.join(EXAMPLES, "boot").inspect}
        abort "boot changed environment" unless before == ENV.to_h
        abort "boot changed directory" unless directory == Dir.pwd
        require "json"
        puts JSON.generate(library: Net::Connector::Netdisco::CLI.instance_method(:initialize).source_location.first)
      RUBY
      output, error, status = Open3.capture3(clean_environment, RbConfig.ruby, "-e", script, chdir: root)
      assert status.success?, error
      assert_equal File.join(ROOT, "lib/net/connector/netdisco/cli.rb"), JSON.parse(output).fetch("library")
    end
  end

  def test_plain_entries_load_script_relative_environment_and_config_from_any_directory
    Dir.mktmpdir do |root|
      examples = File.join(root, "examples")
      FileUtils.mkdir_p(examples)
      File.symlink(File.join(ROOT, "lib"), File.join(root, "lib"))
      %w[boot.rb backup.rb backup_tftp.rb topology.rb].each { |name| FileUtils.cp(File.join(EXAMPLES, name), examples) }
      File.write(File.join(examples, ".env"), "NC_CONFIG=backup.yml\nND_URL=https://inventory.example.invalid\nND_API_KEY=source-test-secret\nNC_PARALLEL=7\n")
      File.write(File.join(examples, "backup.yml"), "netdisco:\n  source: http\nbackup:\n  directory: backups\n")
      environment = clean_environment.merge("HOME" => root, "XDG_CONFIG_HOME" => File.join(root, "config"))
      %w[backup.rb backup_tftp.rb topology.rb].each do |entry|
        [examples, root].each do |directory|
          command = directory == examples ? entry : File.join(examples, entry)
          output, error, status = Open3.capture3(environment, RbConfig.ruby, command, "--show-config", chdir: directory)
          assert status.success?, "#{entry}: #{error}"
          data = JSON.parse(output)
          assert_equal "https://inventory.example.invalid", data.dig("netdisco", "url")
          assert_equal 7, data.dig("backup", "parallel")
          output_directory = data.dig("backup", "directory")
          assert_equal File.join(File.realpath(examples), "backups"), File.join(File.realpath(File.dirname(output_directory)), File.basename(output_directory))
          assert_equal [File.realpath(File.join(examples, ".env"))], (data.dig("sources", "environment_files").map { |path| File.realpath(path) })
          assert_equal [File.realpath(File.join(examples, "backup.yml"))], (data.dig("sources", "configuration_files").map { |path| File.realpath(path) })
          refute_includes output, "source-test-secret"
        end
      end
    end
  end

  private

  def launch(entry, option, bundled: false)
    environment = bundled ? {} : clean_environment
    command = [RbConfig.ruby, entry, option]
    if bundled
      environment["BUNDLE_GEMFILE"] = File.expand_path(ENV.fetch("BUNDLE_GEMFILE", File.join(ROOT, "Gemfile")))
      command = [RbConfig.ruby, "-S", "bundle", "exec", *command]
    end
    Open3.capture3(environment, *command, chdir: EXAMPLES)
  end

  def clean_environment
    environment = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBYOPT\z|RUBYLIB\z|RUBYGEMS_GEMDEPS\z|NC_|ND_|NETDISCO_)/).to_h { |name| [name, nil] }
    environment["GEM_PATH"] = (Gem.path + Gem.loaded_specs.values.map(&:base_dir)).uniq.join(File::PATH_SEPARATOR)
    environment
  end

end
