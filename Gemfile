# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest", "~> 5.0", require: false
  gem "parallel", "~> 1.28", require: false
  gem "rake", "~> 13.0", require: false
  gem "rubocop", "~> 1.91", require: false

  gem "io-console", ">= 0.6", require: false
  gem "timeout", ">= 0.3", require: false
  gem "tmpdir", ">= 0.1", require: false
end

# 显式候选源码联调；普通安装按 gemspec 解析。
gem "ctx_cli", path: ENV.fetch("CTX_CLI_PATH") if ENV["CTX_CLI_PATH"]
