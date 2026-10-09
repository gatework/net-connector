# frozen_string_literal: true

# 公共入口只组合应用流程；每个模块自行声明依赖，不要求调用方维护加载顺序。
require_relative "netdisco/cli"
require_relative "netdisco/backup_run"
