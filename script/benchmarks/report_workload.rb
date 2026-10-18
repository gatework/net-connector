# frozen_string_literal: true

require "json"
require_relative "../../lib/net/connector/netdisco/report"

# 离线合成结果；分别测量构造与统计，不包含设备访问或逐设备明细序列化。
size = Integer(ARGV.fetch(0, "100000"), 10)
repetitions = Integer(ARGV.fetch(1, "20"), 10)
raise ArgumentError, "positive size and repetitions required" unless size.positive? && repetitions.positive?

statuses = %i[backed_up failed filtered saved_with_error sample_limit reported_uploaded reported_with_error]
outcomes = Array.new(size) do |index|
  Net::Connector::Netdisco::Outcome.new(device: nil, status: statuses[index % statuses.size],
                                       backup: nil, error_code: nil, error_type: nil)
end
time = Time.now
measure = lambda do |&operation|
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  operation.call
  { seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
    allocated_objects: GC.stat(:total_allocated_objects) - allocated }
end
batch = nil
construction = measure.call do
  batch = Net::Connector::Netdisco::Batch.new(mode: :backup, outcomes: outcomes, started_at: time, finished_at: time,
                                            callback_errors: [], report_location: nil, report_error: nil)
end
report = Net::Connector::Netdisco::Report.new(batch, policy: :selected)
first = measure.call { report.statistics }
repeated = measure.call { repetitions.times { report.statistics } }
raise "incorrect total" unless report.statistics.fetch(:total) == size
raise "incorrect counts" unless report.counts.values.sum == size

puts JSON.generate(ruby: RUBY_DESCRIPTION, size: size, repetitions: repetitions,
                   construction: construction, first_statistics: first, repeated_statistics: repeated)
