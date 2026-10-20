# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/net/connector/collect/progress"

class CollectProgressTest < Minitest::Test
  def setup
    @output = StringIO.new
    @progress = Net::Connector::Collect::Progress.new(io: @output)
    @device = { "host" => "192.0.2.1", "name" => "LEAF-01" }
    @progress.plan(devices: [@device], total: 2, parallel: 50, label: "VXLAN 只读采集")
  end

  def result(status: :partial, saved: true, **fields)
    { device: @device, status: status, report_saved: saved, duration_ms: 42,
      dimensions: {
        vpc: { status: :complete, issues: [:vpc_not_configured] },
        collection: { status: status, issues: [] },
        l2route_macs: { status: :partial, issues: [:missing_completeness_evidence] }
      }, **fields }
  end

  def finish(results, status: :incomplete, pending: [])
    @progress.finish(status: status, devices: results, pending: pending, directory: "/tmp/fixture-report")
  end

  def test_partial_results_explain_missing_evidence_without_promoting_informational_codes
    item = result
    @progress.start(@device)
    @progress.result(item)
    finish([item])
    assert_includes @output.string, "清单 2 台；本次 1 台；跳过 1 台；并发 50"
    assert_includes @output.string, "192.0.2.1  部分成功（missing_completeness_evidence）"
    assert_includes @output.string, "未完成分类：missing_completeness_evidence=1"
    assert_includes @output.string, "成功 0，部分成功 1，失败 0，跳过 1"
    assert_includes @output.string, "结果 未完成"
    refute_includes @output.string, "vpc_not_configured"
    refute_includes @output.string, "partial"
  end

  def test_unsaved_complete_evidence_is_a_failed_delivery_in_the_final_display
    finish([result(status: :complete, saved: false)])
    assert_includes @output.string, "未完成分类：report_not_saved=1"
    assert_includes @output.string, "成功 0，部分成功 0，失败 1，跳过 1"
    refute_includes @output.string, "结果 完成"
  end

  def test_pending_work_is_not_a_filtered_skip_and_report_status_controls_success
    finish([result(status: :complete)], pending: [{ "host" => "192.0.2.2" }])
    assert_includes @output.string, "成功 1，部分成功 0，失败 0，跳过 1"
    assert_includes @output.string, "未采集 1 台"
    assert_includes @output.string, "结果 未完成"
  end

  def test_native_login_events_move_the_terminal_to_collection_without_command_bodies
    @output.define_singleton_method(:tty?) { true }
    progress = Net::Connector::Collect::Progress.new(io: @output)
    progress.plan(devices: [@device], total: 1, parallel: 1, label: "WIRELESS 只读采集")
    progress.start(@device)
    progress.event(Net::Connector::Log::Event.new(:login_complete,
                                                 { host: @device.fetch("host"), status: :ok, text: "private body" }, redactor: ->(text) { text }))
    progress.tick
    assert_includes @output.string, "登录 0 采集 1"
    refute_includes @output.string, "private body"
  end
end
