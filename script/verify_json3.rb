# frozen_string_literal: true

require "rubygems/package"
require_relative "verify_install"

raise "JSON 3 compatibility check requires JSON 3" unless Gem.loaded_specs.fetch("json").version.segments.first == 3

# 隔离安装复用原始发布包，不能用本地重建或放宽声明代替发布依赖。
specification = Gem.loaded_specs.fetch("textfsm")
raise "JSON 3 requires published TextFSM 0.5.1 or newer" unless specification.version >= Gem::Version.new("0.5.1")
raise "Published TextFSM package cache missing" unless File.file?(specification.cache_file)
package = Gem::Package.new(specification.cache_file)
package.verify
json = Gem.loaded_specs.fetch("json")
dependency = package.spec.runtime_dependencies.find { |entry| entry.name == "json" }
raise "Published TextFSM does not support the selected JSON" unless dependency&.matches_spec?(json)
puts "JSON 3 published dependencies: TextFSM #{specification.version}, JSON #{json.version}"
InstalledPackageCheck.run(PackageCheck.build, candidates: [ENV["CTX_CLI_GEM"], ENV["EXPECT_PTY_GEM"]].compact)
