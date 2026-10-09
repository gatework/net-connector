# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class ReportFilesTest < Minitest::Test
  N = Net::Connector::Netdisco

  def fixture
    device = N::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "H3C" }, rules: N::Rules.new)
    item = N::Outcome.new(device: device, status: :backed_up, backup: nil, error_code: nil, error_type: nil)
    report = N::Batch.new(mode: :backup, outcomes: [item], started_at: Time.now.utc, finished_at: Time.now.utc,
                          callback_errors: [], report_location: nil, report_error: nil).build_report
    plan = N::Planner.new([device]).call(mode: :backup, limit_per_vendor: nil)
    [report, plan]
  end

  def test_text_and_json_generate_device_details_only_once
    original, plan = fixture
    summaries = []
    report_class = Class.new(N::Report) do
      define_method(:summary) { summaries << true; super() }
    end
    Dir.mktmpdir do |directory|
      result = N::Report::Files.write(report_class.new(original.batch), directory: directory, plan: plan, concurrency: 1)
      assert result.policy_success?
      assert_equal 1, JSON.parse(File.read(result.report_location)).fetch("devices").size
      assert_includes File.read(File.join(directory, "summary.txt")), "成功：1"
      assert_equal 1, summaries.size
    end
  end

  def test_json_failure_is_reflected_in_final_text_and_returned_report
    original, plan = fixture
    assert original.policy_success?
    writer = Net::Connector::Storage::PrivateFile.method(:write)
    Dir.mktmpdir do |directory|
      failure = lambda do |path, contents|
        raise IOError, "private failure details" if File.basename(path) == "summary.json"

        writer.call(path, contents)
      end
      Net::Connector::Storage::PrivateFile.stub(:write, failure) do
        result = N::Report::Files.write(original, directory: directory, plan: plan, concurrency: 1)
        refute result.policy_success?
        assert_equal "IOError", result.report_error
        assert_nil result.report_location
        text = File.read(File.join(directory, "summary.txt"))
        assert_includes text, "策略通过：false"
        assert_includes text, "报告错误：IOError"
        refute_includes text, "private failure details"
      end
    end
  end

  def test_text_failure_is_recorded_in_json_before_returning_failure
    original, plan = fixture
    Dir.mktmpdir do |directory|
      N::Report::Text.stub(:write, ->(**) { raise IOError, "private failure details" }) do
        result = N::Report::Files.write(original, directory: directory, plan: plan, concurrency: 1)
        refute result.policy_success?
        document = JSON.parse(File.read(result.report_location))
        refute document.fetch("policy_success")
        assert_equal "IOError", document.fetch("report_error")
        assert_equal 1, document.fetch("succeeded")
        assert_equal 0o600, File.stat(result.report_location).mode & 0o777
        refute_includes JSON.generate(document), "private failure details"
      end
    end
  end

  def test_fallback_json_retains_its_committed_location_when_directory_sync_fails
    original, plan = fixture
    writer = Net::Connector::Storage::PrivateFile.method(:write)
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        Dir.mkdir("batch")
        ["batch", File.join(root, "batch")].each do |directory|
          destination = File.join(directory, "summary.json")
          failure = lambda do |path, contents|
            receipt = writer.call(path, contents)
            raise Net::Connector::Storage::PrivateFile::PersistenceError.new(
              receipt: receipt.with(state: :committed, phase: :directory_sync), underlying_type: "Errno::EIO"
            )
          end
          N::Report::Text.stub(:write, ->(**) { raise IOError, "text unavailable" }) do
            Net::Connector::Storage::PrivateFile.stub(:write, failure) do
              result = N::Report::Files.write(original, directory: directory, plan: plan, concurrency: 1)
              assert_equal destination, result.report_location
              assert_equal "IOError", result.report_error
              refute result.policy_success?
              assert_equal destination, JSON.parse(File.read(destination)).fetch("report_location")
            end
          end
        end
      end
    end
  end

  def test_later_diagnostic_update_preserves_the_first_report_failure_and_committed_path
    original, plan = fixture
    Dir.mktmpdir do |directory|
      original = N::Report::Files.write(original, directory: directory, plan: plan, concurrency: 1)
      failed = original.with_report_error(IOError.new("first failure"), location: original.report_location)
      updated = failed.with(callback_errors: [{ host: nil, error_type: "IOError" }])
      N::Report::Text.stub(:write, ->(**) { raise Errno::ENOSPC }) do
        result = N::Report::Files.write(updated, directory: directory, plan: plan, concurrency: 1)
        assert_equal "IOError", result.report_error
        assert_equal failed.report_diagnostic, result.report_diagnostic
        document = JSON.parse(File.read(result.report_location))
        assert_equal "IOError", document.fetch("report_error")
        assert_equal 1, document.fetch("callback_errors").size
      end
      Net::Connector::Storage::PrivateFile.stub(:write, ->(*) { raise Errno::ENOSPC }) do
        result = N::Report::Files.write(updated, directory: directory, plan: plan, concurrency: 1)
        assert_equal original.report_location, result.report_location
        assert_equal "IOError", result.report_error
        assert_equal failed.report_diagnostic, result.report_diagnostic
      end
    end
  end
end
