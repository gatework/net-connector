# frozen_string_literal: true

# 示例沿用 RubyGems / 调用方 Bundler 的加载环境，不自动切换到其他源码。
project_root = File.expand_path("..", __dir__)
require "bundler/setup" if ENV["BUNDLE_GEMFILE"] && !ENV["BUNDLE_GEMFILE"].empty?
require "net/connector/netdisco"
# 进程中显式指定的配置文件相对启动目录解析；空值采用入口默认配置。
ENV.delete("NC_CONFIG") if ENV["NC_CONFIG"]&.strip&.empty?
ENV["NC_CONFIG"] = File.expand_path(ENV["NC_CONFIG"]) if ENV["NC_CONFIG"]

require "dotenv"
Dotenv.load(File.join(project_root, ".env"))
ENV.delete("NC_CONFIG") if ENV["NC_CONFIG"]&.strip&.empty?

# YAML 和 CLI 中的相对备份、日志路径统一基于项目目录。
Dir.chdir(project_root)
