# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../script/coverage_report"

class CoverageTest < Minitest::Test
  def test_machine_report_lists_unloaded_files_counts_and_runtime_without_source
    with_library do |library, result|
      File.write(File.join(library, "optional.rb"), "value = 1\n")
      data = CoverageReport.new(result, library: library, output: StringIO.new).to_h
      assert_equal 2, data.fetch(:loaded_files)
      assert_equal 3, data.fetch(:total_files)
      assert_equal ["optional.rb"], data.fetch(:unloaded_files)
      assert_equal({ hit: 2, total: 2 }, data.fetch(:coverage).fetch(:lines))
      assert_equal RUBY_DESCRIPTION, data.fetch(:ruby)
      assert_kind_of Hash, data.fetch(:dependencies)
      assert_equal ["net/connector/engine/errors.rb", "net/connector/netdisco/worker.rb"],
                   (data.fetch(:files).map { |file| file.fetch(:path) })
      refute_includes data.inspect, library
      refute_includes data.inspect, "value = 1"
    end
  end

  def test_nc00_ratchet_fails_above_the_old_floor_and_reports_the_group
    with_library do |library, result|
      result.values.last[:branches] = { branch: { covered: 1, missed: 0, hit2: 1, hit3: 1, hit4: 1 } }
      baseline = { "ruby" => RUBY_DESCRIPTION,
                   "groups" => { "批量并发" => { "lines" => { "hit" => 1, "total" => 1 },
                                                 "branches" => { "hit" => 9, "total" => 10 } } } }
      output = StringIO.new
      report = CoverageReport.new(result, library: library, output: output, baseline: baseline)
      refute report.passed?
      assert_equal :regression, report.to_h.fetch(:ratchet).fetch(:status)
      assert_includes output.string, "批量并发 / branches"
      assert_includes output.string, "4/5 < 9/10"
    end
  end

  def test_other_ruby_measurements_are_not_compared_to_this_runtime
    with_library do |library, result|
      baseline = { "ruby" => "a different Ruby runtime", "groups" => {} }
      report = CoverageReport.new(result, library: library, output: StringIO.new, baseline: baseline)
      assert report.passed?
      assert_equal :not_comparable, report.to_h.fetch(:ratchet).fetch(:status)
    end
  end

  def test_exact_threshold_and_branchless_files_pass
    with_library do |library, result|
      result.each_value { |data| data[:lines] = [nil, 1, 1, 1, 1, 0] }
      result.values.first[:branches] = {}
      assert CoverageReport.new(result, library: library, output: StringIO.new).passed?
    end
  end

  def test_line_and_branch_regressions_fail_independently
    %i[lines branches].each do |kind|
      with_library do |library, result|
        data = result.values.last
        # 79.999% 显示为 80.00%，判定必须使用原始计数，不能先四舍五入。
        hits = Array.new(79_999, 1) + Array.new(20_001, 0)
        data[kind] = kind == :lines ? hits : { branch: hits.each_with_index.to_h { |hit, index| [index, hit] } }
        output = StringIO.new
        refute CoverageReport.new(result, library: library, output: output).passed?
        assert_includes output.string, "批量并发"
        assert_includes output.string, "不达标"
        assert_includes output.string, "80.00%"
      end
    end
  end

  def test_missing_critical_file_cannot_be_hidden_by_covered_files
    with_library do |library, result|
      missing = File.join(library, "net/connector/engine/uncovered.rb")
      File.write(missing, "value = 1\n")
      output = StringIO.new
      refute CoverageReport.new(result, library: library, output: output).passed?
      assert_includes output.string, "net/connector/engine/uncovered.rb"
    end
  end

  def test_uncovered_redactor_cannot_hide_inside_the_core_engine_group
    with_library do |library, result|
      other = File.join(library, "net/connector/engine/other.rb")
      File.write(other, "value = 1\n")
      result[other] = { lines: [1], branches: { branch: (1..20).to_h { |index| [index, 1] } } }
      redactor = File.join(library, "net/connector/engine/redactor.rb")
      File.write(redactor, "value = 1\n")
      result[redactor] = { lines: [1], branches: { branch: { missed: 0 } } }
      output = StringIO.new
      report = CoverageReport.new(result, library: library, output: output)
      refute report.passed?
      assert_match(/核心引擎.*通过/, output.string)
      assert_match(/脱敏与错误（含 Redactor）.*不达标/, output.string)
      assert_equal({ hit: 1, total: 2 }, report.to_h.fetch(:groups).fetch("脱敏与错误（含 Redactor）").fetch(:branches))
      result[redactor][:branches] = { branch: { covered: 1 } }
      assert CoverageReport.new(result, library: library, output: StringIO.new).passed?
    end
  end

  def test_unloaded_noncritical_file_is_listed_without_failing_the_gate
    with_library do |library, result|
      File.write(File.join(library, "optional.rb"), "value = 1\n")
      output = StringIO.new
      assert CoverageReport.new(result, library: library, output: output).passed?
      assert_includes output.string, "optional.rb"
    end
  end

  def test_empty_measurement_and_missing_required_group_fail
    with_library do |library, result|
      refute CoverageReport.new({}, library: library, output: StringIO.new).passed?
      File.delete(result.keys.last)
      refute CoverageReport.new(result, library: library, output: StringIO.new).passed?
    end
  end

  def test_passing_tests_with_insufficient_coverage_exit_unsuccessfully
    hook = File.expand_path("../script/coverage.rb", __dir__)
    output, errors, status = Open3.capture3(RbConfig.ruby, "-r#{hook}", "-e", <<~RUBY)
      class PassingTest < Minitest::Test
        def test_pass = assert(true)
      end
    RUBY
    refute status.success?, errors
    assert_includes output, "1 runs, 1 assertions, 0 failures"
    assert_includes output, "不达标"
  end

  def test_passing_coverage_does_not_mask_test_failures
    report = File.expand_path("../script/coverage_report.rb", __dir__)
    hook = File.expand_path("../script/coverage.rb", __dir__)
    output, errors, status = Open3.capture3(RbConfig.ruby, "-r#{report}", "-e", <<~RUBY)
      class CoverageReport
        def passed? = true
      end
      require #{hook.inspect}
      class FailingTest < Minitest::Test
        def test_fail = flunk("expected failure")
      end
    RUBY
    refute status.success?, errors
    assert_includes output, "1 failures"
  end

  private

  def with_library
    Dir.mktmpdir("net-connector-coverage-") do |library|
      result = %w[engine/errors.rb netdisco/worker.rb].to_h do |relative|
        path = File.join(library, "net/connector", relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "value = 1\n")
        [path, { lines: [1], branches: { branch: { covered: 1 } } }]
      end
      yield library, result
    end
  end
end
