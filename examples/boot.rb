# frozen_string_literal: true

# 示例加载相邻发行目录的代码；第三方依赖沿用调用方环境，不切换 Gemfile。
require "bundler/setup" if ENV["BUNDLE_GEMFILE"] && !ENV["BUNDLE_GEMFILE"].empty?
require_relative "../lib/net/connector/netdisco"
