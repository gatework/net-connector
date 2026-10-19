# frozen_string_literal: true

# 拓扑发现、描述审计和显式应用；默认只读规划，--help / --help-all / --examples 查看用法。
require_relative "boot"

exit Net::Connector::Netdisco::CLI::Topology.new(load_env: true, default_env: File.expand_path("../.env", __dir__), default_config: File.expand_path("topology.yml", __dir__),
                                              default_directory: ENV["NC_TOPOLOGY_DIRECTORY"] || File.expand_path("topologys", __dir__)).run
