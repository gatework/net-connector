# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

desc "Check Ruby code and gem declarations"
task :lint do
  ruby "-S", "rubocop"
end

namespace :lint do
  desc "Validate GitHub Actions workflows"
  task :workflows do
    require_relative "script/tools"
    sh BuildTools.path("actionlint"), "-color", *Dir[".github/workflows/*.yml"]
  end
end

namespace :security do
  desc "Scan publishable source and available Git history; redact all findings"
  task :check do
    ruby "script/security.rb"
  end
end

namespace :package do
  desc "Build, inspect, scan and verify an isolated gem installation"
  task :verify do
    require_relative "script/package"
    artifact = PackageCheck.build
    ruby "script/verify_install.rb", artifact
  end
end

desc "Run the same security, lint, tests and package checks as CI"
task ci: ["security:check", :lint, "lint:workflows", :test, "package:verify"]

namespace :release do
  desc "Check code and the release artifact without publishing or requiring archived notes"
  task check: :ci
end

task default: %i[lint test]
