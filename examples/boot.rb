# frozen_string_literal: true

# 示例沿用 RubyGems / 调用方 Bundler 的加载环境，不自动切换到源码。
project_root = File.expand_path("..", __dir__)
# 进程中显式指定的配置文件相对启动目录解析。
ENV["NC_CONFIG"] = File.expand_path(ENV["NC_CONFIG"]) if ENV["NC_CONFIG"] && !ENV["NC_CONFIG"].empty?

require "dotenv"
Dotenv.load(File.join(project_root, ".env"))

# .env 和 YAML 中的相对备份、日志路径统一基于项目目录。
Dir.chdir(project_root)
