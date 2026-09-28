# frozen_string_literal: true

require "rubygems/package"
require_relative "verify_install"

raise "JSON 3 compatibility check requires JSON 3" unless Gem.loaded_specs.fetch("json").version.segments.first == 3

# 将同一份受测源码真正构建安装，避免 path gem 绕过消费者依赖检查。
specification = Gem.loaded_specs.fetch("textfsm")
expected = File.expand_path("../tmp/json3/textfsm", __dir__)
raise "JSON 3 requires the explicit textfsm source fixture" unless specification.full_gem_path == expected

artifact = File.expand_path("../tmp/ci/#{specification.file_name}", __dir__)
FileUtils.mkdir_p(File.dirname(artifact))
Dir.chdir(expected) { Gem::Package.build(specification, false, false, artifact) }
specification.define_singleton_method(:cache_file) { artifact }
puts "JSON 3 source compatibility: textfsm metadata override; not a published-dependency result"
InstalledPackageCheck.run(PackageCheck.build)
