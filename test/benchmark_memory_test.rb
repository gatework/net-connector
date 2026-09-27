# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "rbconfig"

class BenchmarkMemoryTest < Minitest::Test
  SCRIPT = File.expand_path("../script/benchmark_memory.rb", __dir__)

  def test_large_cartesian_workload_is_rejected_before_allocating_or_starting_workers
    Dir.mktmpdir do |directory|
      output = File.join(directory, "results")
      _stdout, errors, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--response-bytes", (32 * 1024 * 1024).to_s,
                                              "--commands", "100", "--concurrency", "16", "--directory", output)
      refute status.success?
      assert_includes errors, "128 MiB"
      refute File.exist?(output)
    end
  end

  def test_existing_result_directory_is_not_overwritten
    Dir.mktmpdir do |directory|
      path = File.join(directory, "results.json")
      File.write(path, "previous measurement")
      _stdout, errors, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--suite", "smoke", "--directory", directory)
      refute status.success?
      assert_includes errors, "already exists"
      assert_equal "previous measurement", File.read(path)
    end
  end
end
