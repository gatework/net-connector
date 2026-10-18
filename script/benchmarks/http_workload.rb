# frozen_string_literal: true

require "json"
require "uri"
require_relative "../../lib/net/connector/netdisco"
require_relative "../../test/support/inventory_http_server"

# 实际本地 TCP 分页，记录耗时、连接数和对象分配；不包含现场网络时延。
pages, runs = ARGV.empty? ? [200, 5] : ARGV.map { |value| Integer(value, 10) }
unless [pages, runs].all? { |value| value.is_a?(Integer) && value.positive? }
  abort "usage: ruby script/benchmarks/http_workload.rb [pages runs]"
end
samples = Array.new(runs) do
  reply = lambda do |request|
    offset = URI.decode_www_form(URI.parse(request.split[1]).query).to_h.fetch("offset").to_i
    offset < pages ? JSON.generate([{ "ip" => "fixture-#{offset}.example.invalid" }]) : "[]"
  end
  sample = nil
  InventoryHTTPServer.open(count: pages + 1, reply: reply) do |server|
    source = Net::Connector::Netdisco::Inventory::HTTP.new(url: server.url, api_key: "fixture", page_size: 1)
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows = source.devices
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    objects = GC.stat(:total_allocated_objects) - allocated
    raise "pagination lost or reordered devices" unless rows.map { |row| row.fetch("ip") } ==
                                                       Array.new(pages) { |index| "fixture-#{index}.example.invalid" }

    sample = { seconds: elapsed, allocated_objects: objects, connections: server.connections }
  end
  sample
end
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, pages: pages, samples: samples)
