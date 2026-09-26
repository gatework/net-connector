# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest", "~> 5.0", require: false
  # parallel 2.x 不支持项目的最低 Ruby 3.2。
  gem "parallel", "~> 1.28", require: false
  gem "rake", "~> 13.0", require: false
  gem "rubocop", "~> 1.91", require: false

  gem "io-console", ">= 0.6", "< 1.0", require: false
  gem "timeout", ">= 0.3", "< 1.0", require: false
  gem "tmpdir", ">= 0.1", "< 1.0", require: false
end
