# frozen_string_literal: true

require "json"
require "tmpdir"
require "open3"
require_relative "../../lib/net/connector"

# 使用真实密钥检查与私有文件提交，测量共享信任文件的合并成本，不包含 SSH 登录。
rows, additions, runs = ARGV.empty? ? [30_000, 3_000, 5] : ARGV.map { |value| Integer(value, 10) }
unless [rows, additions, runs].all? { |value| value.is_a?(Integer) && value.positive? }
  abort "usage: ruby script/benchmarks/known_hosts_workload.rb [rows additions runs]"
end

Dir.mktmpdir("nc-known-hosts-benchmark-") do |directory|
  key_path = File.join(directory, "key")
  _output, status = Open3.capture2e("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key_path)
  raise "fixture key generation failed" unless status.success?

  key = File.read(key_path + ".pub").split.first(2).join(" ")
  original = Array.new(rows) { |index| "old-#{index}.example.invalid #{key}\n" }.join
  staged = Array.new(additions) { |index| "new-#{index}.example.invalid #{key}\n" }.join
  path = File.join(directory, "known_hosts")
  configuration = Net::Connector::Configuration.new(host: "192.0.2.1", username: "benchmark", known_hosts: path)
  samples = Array.new(runs) do
    File.write(path, original)
    entry = Net::Connector::KnownHosts.new(configuration)
    File.write(entry.path, original + staged)
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entry.commit
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    objects = GC.stat(:total_allocated_objects) - allocated
    raise "merge lost or reordered host keys" unless File.binread(path) == original + staged

    { seconds: elapsed, allocated_objects: objects }
  ensure
    entry&.close
  end
  puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, rows: rows, additions: additions, samples: samples)
end
