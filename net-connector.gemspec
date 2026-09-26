# frozen_string_literal: true

require_relative "lib/net/connector/version"

Gem::Specification.new do |spec|
  spec.name = "net-connector"
  spec.version = Net::Connector::VERSION
  spec.authors = ["net-connector contributors"]
  spec.homepage = "https://github.com/gatework/net-connector"
  spec.summary = "Network device CLI sessions and Netdisco-driven concurrent backups"
  spec.description = "Automate network device login, configuration collection, command scripts, " \
                     "interactive prompts, redacted logging, and Netdisco inventory backups."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  # 使用明确的发布清单；本地凭据、设备备份、日志和开发产物不能进入安装包。
  spec.files = Dir["lib/**/*.rb", "lib/net/connector/templates/*.textfsm", "lib/net/connector/templates/index",
                   "exe/net-connector-backup", "docs/architecture.md", "docs/RELEASING.md", "docs/VERIFICATION.md",
                   "README.md", "LICENSE", "CHANGELOG.md"].sort
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["net-connector-backup"]
  spec.add_dependency "expect-pty", "~> 0.3.1"
  spec.add_dependency "activesupport", ">= 7.2", "< 9"
  spec.add_dependency "textfsm", "~> 0.2.0"
  # 直接使用的标准库 gem 也要声明，最小 Bundler 应用不能借用开发工具的依赖。
  spec.add_dependency "digest", ">= 3.1", "< 4.0"
  spec.add_dependency "english", ">= 0.7", "< 1.0"
  spec.add_dependency "fileutils", ">= 1.6", "< 2.0"
  spec.add_dependency "forwardable", "~> 1.3"
  spec.add_dependency "ipaddr", "~> 1.2"
  spec.add_dependency "json", "~> 2.0"
  spec.add_dependency "net-http", ">= 0.3", "< 1.0"
  spec.add_dependency "open3", ">= 0.1", "< 1.0"
  spec.add_dependency "openssl", ">= 3.0", "< 5.0"
  spec.add_dependency "optparse", ">= 0.3", "< 1.0"
  spec.add_dependency "securerandom", ">= 0.2", "< 1.0"
  spec.add_dependency "shellwords", ">= 0.1", "< 1.0"
  spec.add_dependency "stringio", "~> 3.0"
  spec.add_dependency "tempfile", ">= 0.1", "< 1.0"
  spec.add_dependency "time", ">= 0.2", "< 1.0"
  spec.add_dependency "uri", ">= 0.12", "< 2.0"
  spec.add_dependency "yaml", ">= 0.2", "< 1.0"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/net-connector"
  spec.metadata["source_code_uri"] = "https://github.com/gatework/net-connector"
  spec.metadata["changelog_uri"] = "https://github.com/gatework/net-connector/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/gatework/net-connector/issues"
end
