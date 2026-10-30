# frozen_string_literal: true

require_relative "lib/net/connector/version"

Gem::Specification.new do |spec|
  spec.name = "net-connector"
  spec.version = Net::Connector::VERSION
  spec.authors = ["net-connector contributors"]
  spec.homepage = "https://github.com/gatework/net-connector"
  spec.summary = "Network device CLI sessions and inventory-driven automation"
  spec.description = "Manage SSH and Telnet sessions with network devices, execute command scripts, " \
                     "collect and back up configurations, and discover and reconcile interface " \
                     "descriptions using Netdisco inventories."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  # 使用明确的发布清单；本地凭据、设备备份、日志和开发产物不能进入安装包。
  spec.files = Dir["lib/**/*.rb", "lib/net/connector/netdisco/ssh/archive/worker.py",
                   "lib/net/connector/textfsm/**/*.textfsm", "lib/net/connector/textfsm/index",
                   "bin/net-backup", "docs/architecture.md", "docs/RELEASING.md", "docs/VERIFICATION.md",
                   "docs/templates.md", "docs/vendors.md", "docs/usage.md", "docs/usage.zh-CN.md", "docs/netdisco.md", "docs/netdisco.zh-CN.md",
                   "examples/backup.example.yml", "examples/inventory.yml",
                   "README.md", "README.zh-CN.md", "LICENSE", "CHANGELOG.md", "SECURITY.md", "CONTRIBUTING.md"].sort
  spec.require_paths = ["lib"]
  spec.bindir = "bin"
  spec.executables = ["net-backup"]
  # 使用当前 Session 与缓冲字节查询契约，具体版本由宿主应用锁定。
  spec.add_dependency "ctx_cli", ">= 0.5.0", "< 0.6"
  spec.add_dependency "expect-pty", ">= 0.9.6", "< 0.10"
  spec.add_dependency "textfsm", ">= 0.5.1"
  spec.add_dependency "pg"
  spec.add_dependency "dotenv"
  # 直接使用的标准库 gem 也要声明，最小 Bundler 应用不能借用开发工具的依赖。
  spec.add_dependency "digest"
  spec.add_dependency "fileutils"
  spec.add_dependency "forwardable"
  spec.add_dependency "io-console"
  spec.add_dependency "ipaddr"
  spec.add_dependency "json"
  spec.add_dependency "logger"
  spec.add_dependency "net-http"
  spec.add_dependency "open3"
  spec.add_dependency "openssl"
  spec.add_dependency "optparse"
  spec.add_dependency "securerandom"
  spec.add_dependency "shellwords"
  spec.add_dependency "stringio"
  spec.add_dependency "tempfile"
  spec.add_dependency "time"
  spec.add_dependency "timeout"
  spec.add_dependency "uri"
  spec.add_dependency "yaml"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/net-connector"
  spec.metadata["source_code_uri"] = "https://github.com/gatework/net-connector"
  spec.metadata["changelog_uri"] = "https://github.com/gatework/net-connector/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/gatework/net-connector/issues"
end
