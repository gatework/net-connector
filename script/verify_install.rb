# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"
require "bundler"
require_relative "package"

module InstalledPackageCheck
  def self.run(artifact)
    artifact = File.expand_path(artifact)
    package = PackageCheck.verify(artifact)
    # 只复制运行时依赖闭包的缓存，禁止开发 Gemfile 给最小应用补齐遗漏的依赖。
    dependencies = []
    pending = package.runtime_dependencies.dup
    until pending.empty?
      dependency = pending.shift
      next if dependencies.any? { |spec| spec.name == dependency.name }

      spec = Gem.loaded_specs.fetch(dependency.name)
      raise "Incompatible installed dependency: #{dependency.name}" unless dependency.matches_spec?(spec)

      dependencies << spec
      pending.concat(spec.runtime_dependencies)
    end

    bundler = Gem.loaded_specs.fetch("bundler")
    cleaned = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBYOPT\z|RUBYLIB\z|RUBYGEMS_GEMDEPS\z)/).to_h { |key| [key, nil] }
    Dir.mktmpdir("net-connector-installed-") do |directory|
      gems = File.join(directory, "gems")
      environment = cleaned.merge("GEM_HOME" => gems, "GEM_PATH" => gems)
      (dependencies + [bundler]).each do |spec|
        if File.file?(spec.cache_file)
          FileUtils.cp(spec.cache_file, directory)
        elsif !spec.default_gem?
          raise "Missing gem cache: #{spec.full_name}; run bundle install before installed-package checks"
        end
      end
      FileUtils.cp(artifact, directory)
      FileUtils.cp(File.join(__dir__, "smoke.rb"), directory)
      PackageCheck.command(environment, RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document",
                           File.join(directory, File.basename(artifact)), chdir: directory)
      PackageCheck.command(environment, RbConfig.ruby, "smoke.rb", "plain", chdir: directory)
      # 在 Gemfile 中仅声明消费者需要安装的 gem。
      # Ruby 随附的默认 Bundler 未必有 .gem 缓存，在隔离 GEM_HOME 下仍可按版本加载。
      if File.file?(bundler.cache_file)
        PackageCheck.command(environment, RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document",
                             File.join(directory, File.basename(bundler.cache_file)), chdir: directory)
      end
      File.write(File.join(directory, "Gemfile"), "source \"https://rubygems.org\"\ngem \"net-connector\", \"= #{package.version}\"\n")
      environment["BUNDLE_IGNORE_CONFIG"] = "true"
      PackageCheck.command(environment, RbConfig.ruby, "-S", "bundle", "_#{bundler.version}_", "lock", "--local", chdir: directory)
      PackageCheck.command(environment, RbConfig.ruby, "-S", "bundle", "_#{bundler.version}_", "exec", RbConfig.ruby,
                           "-rbundler/setup", "smoke.rb", "bundler", chdir: directory)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    InstalledPackageCheck.run(ARGV.fetch(0))
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
