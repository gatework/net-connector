# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"
require "bundler"
require_relative "package"

# 从校验过的 gem 构造普通与 Bundler 最小应用，验证消费者不依赖源码检出目录。
module InstalledPackageCheck
  def self.run(artifact, candidates: [])
    artifact = File.expand_path(artifact)
    package = PackageCheck.verify(artifact)
    # 显式候选包参与依赖闭包；同版本也必须安装并校验给定制品字节。
    candidate_files = candidates.to_h do |path|
      path = File.expand_path(path)
      candidate = Gem::Package.new(path)
      candidate.verify
      raise "Unexpected CLI candidate" unless candidate.spec.name == "ctx_cli"
      [candidate.spec.name, [candidate.spec, path]]
    end
    # 只复制运行时依赖闭包的缓存，禁止开发 Gemfile 给最小应用补齐遗漏的依赖。
    dependencies = []
    pending = package.runtime_dependencies.dup
    until pending.empty?
      dependency = pending.shift
      next if dependencies.any? { |spec| spec.name == dependency.name }

      spec = candidate_files[dependency.name]&.first || Gem.loaded_specs.fetch(dependency.name)
      raise "Incompatible installed dependency: #{dependency.name}" unless dependency.matches_spec?(spec)

      dependencies << spec
      pending.concat(spec.runtime_dependencies)
    end

    bundler = Gem.loaded_specs.fetch("bundler")
    cleaned = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBYOPT\z|RUBYLIB\z|RUBYGEMS_GEMDEPS\z)/).to_h { |key| [key, nil] }
    Dir.mktmpdir("net-connector-installed-") do |directory|
      gems = File.join(directory, "gems")
      environment = cleaned.merge("GEM_HOME" => gems, "GEM_PATH" => gems)
      dependencies.each do |spec|
        cache = candidate_files[spec.name]&.last || spec.cache_file
        if File.file?(cache)
          FileUtils.cp(cache, directory)
        elsif !spec.default_gem?
          raise "Missing gem cache: #{spec.full_name}; run bundle install before installed-package checks"
        end
      end
      # setup-ruby 的 Bundler 可能已安装但没有 .gem 缓存；仅补取测试工具本身，
      # 运行时依赖仍必须来自已解析的本地缓存，保持消费者环境的隔离性。
      if File.file?(bundler.cache_file)
        FileUtils.cp(bundler.cache_file, directory)
      elsif !bundler.default_gem?
        PackageCheck.command(cleaned, RbConfig.ruby, "-S", "gem", "fetch", "bundler", "--version",
                             bundler.version.to_s, chdir: directory)
      end
      FileUtils.cp(artifact, directory)
      FileUtils.cp(File.join(__dir__, "smoke.rb"), directory)
      # JSON 2/3 矩阵必须实际安装所选版本，不能被 Ruby 默认 gem 静默替代。
      json = dependencies.find { |spec| spec.name == "json" }
      if json && File.file?(File.join(directory, "#{json.full_name}.gem"))
        PackageCheck.command(environment, RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document",
                             File.join(directory, "#{json.full_name}.gem"), chdir: directory)
      end
      PackageCheck.command(environment, RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document",
                           File.join(directory, File.basename(artifact)), chdir: directory)
      candidate_files.each_value do |spec, path|
        Dir.mktmpdir("cli-candidate-") do |source|
          Gem::Package.new(path).extract_files(source)
          spec.files.each do |file|
            installed = File.join(gems, "gems", spec.full_name, file)
            raise "CLI candidate byte mismatch: #{file}" unless File.binread(installed) == File.binread(File.join(source, file))
          end
        end
      end
      PackageCheck.command(environment, RbConfig.ruby, "smoke.rb", "plain", chdir: directory)
      # 在 Gemfile 中仅声明消费者需要安装的 gem。
      # Ruby 随附的默认 Bundler 未必有 .gem 缓存，在隔离 GEM_HOME 下仍可按版本加载。
      if File.file?(File.join(directory, "#{bundler.full_name}.gem"))
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
    InstalledPackageCheck.run(ARGV.fetch(0), candidates: ARGV.drop(1))
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
