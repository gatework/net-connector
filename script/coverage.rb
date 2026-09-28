# frozen_string_literal: true

require "coverage"
require "fileutils"
require "json"
require_relative "coverage_report"

# 在测试加载库文件之前启用统计；after_run 的非零退出码传给 Rake，
# 使 test、ci 和 release:check 共用门槛，测试失败也不会被覆盖率成功掩盖。
Coverage.start(lines: true, branches: true)
require "minitest/autorun"

Minitest.after_run do
  baseline = JSON.parse(File.read(File.join(__dir__, "coverage-baseline.json")))
  report = CoverageReport.new(Coverage.result, baseline: baseline)
  passed = report.passed?
  destination = File.expand_path(ENV.fetch("NC_COVERAGE_OUTPUT", "../tmp/coverage/summary.json"), __dir__)
  FileUtils.mkdir_p(File.dirname(destination))
  File.write(destination, JSON.pretty_generate(report.to_h) + "\n")
  exit 1 unless passed
end
