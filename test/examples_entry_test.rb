# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

# 必须以使用者实际的启动方式验证，不能在测试进程中预加载新模块来掩盖依赖错误。
class ExamplesEntryTest < Minitest::Test
  EXAMPLES = File.expand_path("../examples", __dir__)
  ROOT = File.dirname(EXAMPLES)

  def test_explicit_source_load_path_runs_help_and_examples_from_the_examples_directory
    %w[backup.rb backup_tftp.rb topology.rb].each do |entry|
      %w[--help --examples].each do |option|
        output, error, status = launch(entry, option)
        assert status.success?, "#{entry} #{option}: #{error}"
        assert_includes output, entry == "topology.rb" ? "--apply" : "--plan"
        refute_match(/NameError|LoadError|net-connector-optimization/, error)
      end
    end
  end

  def test_trunk_bundler_uses_its_own_implementation
    %w[backup.rb backup_tftp.rb topology.rb].each do |entry|
      output, error, status = launch(entry, "--help", bundled: true)
      assert status.success?, "bundle exec ruby #{entry}: #{error}"
      assert_includes output, "--name"
      refute_match(/NameError|LoadError|net-connector-optimization/, error)
    end
  end

  private

  def launch(entry, option, bundled: false)
    environment = clean_environment
    command = [RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", entry, option]
    if bundled
      environment["BUNDLE_GEMFILE"] = File.join(ROOT, "Gemfile")
      command = [RbConfig.ruby, "-S", "bundle", "exec", *command]
    end
    Open3.capture3(environment, *command, chdir: EXAMPLES)
  end

  def clean_environment
    ENV.keys.grep(/\A(?:BUNDLE_|RUBYOPT\z|RUBYLIB\z)/).to_h { |name| [name, nil] }
  end

end
