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
end
