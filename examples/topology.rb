# frozen_string_literal: true

# 拓扑发现、描述审计和显式应用；默认只读规划，--help / --help-all / --examples 查看用法。
require_relative "boot"

exit Net::Connector::Netdisco::CLI::Topology.new().run
