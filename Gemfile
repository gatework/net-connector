# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  # 示例读取项目根目录 .env；不进入库的运行时依赖。
  gem "dotenv", ">= 3.0", require: false
  gem "minitest", "~> 5.0", require: false
  # parallel 2.x 不支持项目的最低 Ruby 3.2。
  gem "parallel", "~> 1.28", require: false
  gem "rake", "~> 13.0", require: false
  gem "rubocop", "~> 1.91", require: false

  gem "io-console", ">= 0.6", require: false
  gem "timeout", ">= 0.3", require: false
  gem "tmpdir", ">= 0.1", require: false
end
