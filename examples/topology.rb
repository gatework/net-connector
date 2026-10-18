# frozen_string_literal: true

# 拓扑发现、描述审计和显式应用；默认配置及输出目录由示例注入。
require_relative "boot"

exit Net::Connector::Netdisco::CLI::Topology.new(load_env: true, default_config: File.expand_path("topology.yml", __dir__),
                                              default_directory: ENV["NC_TOPOLOGY_DIRECTORY"] || File.expand_path("topology_reports", __dir__)).run
