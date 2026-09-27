# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
  task.ruby_opts << "-r#{File.expand_path("script/coverage.rb", __dir__)}"
end

desc "检查 Ruby 代码和 gem 声明"
task :lint do
  ruby "-S", "rubocop"
end

namespace :lint do
  desc "校验 GitHub Actions 工作流"
  task :workflows do
    require_relative "script/tools"
    sh BuildTools.path("actionlint"), "-color", *Dir[".github/workflows/*.yml"]
  end
end

namespace :security do
  desc "扫描发布源码和完整 Git 历史，脱敏输出检查结果"
  task :check do
    ruby "script/security.rb"
  end
end

namespace :package do
  desc "构建、检查并扫描 gem，验证隔离安装"
  task :verify do
    require_relative "script/package"
    artifact = PackageCheck.build
    ruby "script/verify_install.rb", artifact
  end
end

desc "执行与 CI 相同的敏感数据、lint、测试和打包检查"
task ci: ["security:check", :lint, "lint:workflows", :test, "benchmark:smoke", "package:verify"]

namespace :benchmark do
  desc "以小型合成数据检查离线基准及本地 PTY；不设置机器性能阈值"
  task :smoke do
    ruby "script/benchmark_memory.rb", "--suite", "smoke"
  end
end

namespace :release do
  desc "检查代码及发布包，不上传，也不要求提前归档更新记录"
  task check: :ci
end

task default: %i[lint test]
