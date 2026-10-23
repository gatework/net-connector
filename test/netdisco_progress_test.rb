# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "timeout"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class NetdiscoProgressTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def test_disabled_progress_does_not_read_the_report
    output = StringIO.new
    Netdisco::Progress.new(io: output, enabled: false).finish(Object.new)
    assert_empty output.string
  end

  def test_finish_includes_blocking_inventory_issues_and_policy_result
    device = Netdisco::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "unknown" }, rules: Netdisco::Rules.new)
    outcome = Netdisco::Outcome.new(device: device, status: :unsupported_vendor, backup: nil, error_code: nil, error_type: nil)
    report = Netdisco::Batch.new(mode: :backup, outcomes: [outcome], started_at: Time.now.utc, finished_at: Time.now.utc,
                                 callback_errors: [], report_location: nil, report_error: nil).build_report(policy: :selected)
    output = StringIO.new
    Netdisco::Progress.new(io: output).finish(report)
    assert_includes output.string, "unsupported_vendor=1"
    assert_includes output.string, "result incomplete"
  end

  def test_topology_result_filters_unknown_error_codes
    output = StringIO.new
    progress = Netdisco::Progress.new(io: output, verbose: true)
    device = Struct.new(:host, :vendor).new("192.0.2.1", :h3c)
    progress.operation_plan([device], parallel: 1, label: "拓扑规划")
    progress.start(device)
    progress.operation_result(device: device, status: :failed, duration_ms: 10, error_code: :private_diagnostic)
    refute_includes output.string, "private_diagnostic"
    assert_includes output.string, "elapsed 10 ms"
  end

  def test_live_events_and_private_file_log_coexist_without_configuration_output
    output = StringIO.new
    progress = Netdisco::Progress.new(io: output, verbose: true)
    secret = "private-configuration-marker"
    Dir.mktmpdir do |directory|
      transport = ConnectorFake.new("router#", "router#", "#{secret}\nrouter#")
      transport.on_write = lambda do |bytes, _timeout|
        next unless bytes == "show running-config\n"

        assert_includes output.string, "Executing command: show running-config; waiting for response"
        refute_includes output.string, "Backup saved"
      end
      factory = lambda do |device, settings|
        device.build_connector(**settings, transport: transport, on_event: progress.method(:event))
      end
      settings = Netdisco::Settings.new(env: {}, defaults: { "NC_LOG_DIRECTORY" => File.join(directory, "logs") })
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "Cisco", "os" => "ios" }])
      fleet = Netdisco::Fleet.new(inventory: inventory, settings: settings, connector_factory: factory,
                                  credentials: ->(_) { { username: "audit", password: "private-password" } })
      plan = fleet.plan_backup
      progress.plan(plan, parallel: 1)
      report = fleet.backup_all(directory: directory, plan: plan, on_start: progress.method(:start), on_result: progress.method(:result))
      progress.finish(report)
      assert report.success?, report.summary.inspect
      assert_includes output.string, "Login succeeded"
      assert_includes output.string, "[1/1 100% running 0]"
      assert_includes output.string, "Backup saved"
      refute_includes output.string, secret
      refute_includes output.string, "private-password"
      log = File.read(File.join(directory, "logs", "192.0.2.1.log"))
      assert_includes log, "event=command_start"
      refute_includes log, secret
    end
  end

  def test_concurrent_results_count_only_selected_tasks_and_keep_failure_distinct
    output = StringIO.new
    progress = Netdisco::Progress.new(io: output, verbose: true)
    devices = 10.times.map { |i| Struct.new(:host, :vendor).new("192.0.2.#{i + 1}", :h3c) }
    plan = Struct.new(:ready, :inventory).new(devices, devices + [nil, nil])
    progress.plan(plan, parallel: 4)
    devices.map do |device|
      Thread.new do
        progress.start(device)
        outcome = Netdisco::Outcome.new(device: device, status: :failed, backup: nil,
                                        error_code: :authentication_error, error_type: "Net::Connector::AuthenticationError", duration_ms: 10)
        progress.result(outcome)
      end
    end.each(&:value)
    assert_equal 21, output.string.lines.size
    assert_includes output.string, "selected 10; skipped 2 devices"
    assert_includes output.string.lines.last, "[10/10 100% running 0]"
    assert_equal 10, output.string.scan("Incomplete (authentication_error)").size
    refute_includes output.string, "Backup saved"
  end

  def test_tftp_progress_is_not_server_verification_and_quiet_mode_is_silent
    [true, false].each do |enabled|
      output = StringIO.new
      progress = Netdisco::Progress.new(io: output, enabled: enabled, verbose: true)
      device = Struct.new(:host, :vendor).new("192.0.2.1", :h3c)
      progress.plan(Struct.new(:ready, :inventory).new([device], [device]), parallel: 1)
      progress.start(device)
      progress.result(Netdisco::Outcome.new(device: device, status: :reported_uploaded, backup: nil,
                                            error_code: nil, error_type: nil, duration_ms: 10))
      if enabled
        assert_includes output.string, "server file has not been verified"
      else
        assert_empty output.string
      end
    end
  end

  def test_compact_terminal_refreshes_stages_and_preserves_failures
    output = StringIO.new
    output.define_singleton_method(:tty?) { true }
    progress = Netdisco::Progress.new(io: output)
    device = Struct.new(:host, :vendor).new("192.0.2.1", :h3c)
    progress.plan(Struct.new(:ready, :inventory).new([device], [device]), parallel: 1)
    progress.start(device)
    assert_includes output.string, "Logging in 1"
    progress.result(Netdisco::Outcome.new(device: device, status: :failed, backup: nil,
                                          error_code: :authentication_error, error_type: "Error", duration_ms: 10))
    assert_includes output.string, "1/1 100%"
    assert_includes output.string, "incomplete 1"
    assert_includes output.string, "192.0.2.1  Incomplete (authentication_error)"
    assert_includes output.string, "\r\e[2K"
    refute_includes output.string, "Starting backup"
  end

  def test_heartbeat_updates_elapsed_and_oldest_task_without_device_output
    output = StringIO.new
    output.define_singleton_method(:tty?) { true }
    progress = Netdisco::Progress.new(io: output)
    clock = 100.0
    progress.define_singleton_method(:monotonic) { clock }
    device = Struct.new(:host, :vendor).new("192.0.2.1", :h3c)
    progress.plan(Struct.new(:ready, :inventory).new([device], [device]), parallel: 1)
    progress.start(device)
    clock += 12
    progress.tick
    assert_includes output.string, "elapsed 00:00:12"
    assert_includes output.string, "remaining estimating"
    assert_includes output.string, "longest 192.0.2.1 logging in 12s"
  end

  def test_progress_worker_is_joined_on_exception_and_clears_display
    output = StringIO.new
    output.define_singleton_method(:tty?) { true }
    progress = Netdisco::Progress.new(io: output)
    before = Thread.list
    assert_raises(RuntimeError) do
      progress.with_updates do
        progress.tick
        raise "test failure"
      end
    end
    assert_empty Thread.list - before
    assert output.string.end_with?("\r\e[2K\e[1A\r\e[2K")
  end

  def test_heartbeat_output_failure_preserves_result_and_primary_interrupt
    # Timeout 自己的常驻计时线程不属于待回收的进度线程。
    Timeout.timeout(1) { Thread.pass }
    [nil, Interrupt.new("user cancellation")].each do |failure|
      attempted = Queue.new
      output = StringIO.new
      output.define_singleton_method(:tty?) { true }
      output.define_singleton_method(:write) do |*|
        attempted << true
        raise IOError, "private terminal diagnostic"
      end
      progress = Netdisco::Progress.new(io: output)
      before = Thread.list
      operation = lambda do
        progress.with_updates do
          Timeout.timeout(3) { attempted.pop }
          raise failure if failure

          :completed_report
        end
      end
      if failure
        assert_same failure, assert_raises(Interrupt, &operation)
      else
        assert_equal :completed_report, operation.call
      end
      assert_equal({ host: nil, error_type: "IOError" }, progress.output_error)
      assert_empty Thread.list - before
      progress.tick
      assert_empty attempted
    end
  end

  def test_unexpected_heartbeat_failure_is_reported_without_replacing_result_or_interrupt
    Timeout.timeout(1) { Thread.pass }
    [nil, Interrupt.new("foreground cancellation")].each do |failure|
      started = Queue.new
      output = StringIO.new
      output.define_singleton_method(:tty?) { true }
      progress = Netdisco::Progress.new(io: output)
      progress.define_singleton_method(:tick) { started << true; raise RuntimeError, "private display error" }
      before = Thread.list
      operation = lambda do
        progress.with_updates do
          Timeout.timeout(3) { started.pop }
          raise failure if failure

          :completed_report
        end
      end
      if failure
        assert_same failure, assert_raises(Interrupt, &operation)
      else
        assert_equal :completed_report, operation.call
      end
      assert_equal({ host: nil, error_type: "RuntimeError" }, progress.output_error)
      assert_empty Thread.list - before
      refute_includes output.string, "private display error"
    end
  end

  def test_final_display_cancellation_preserves_primary_and_propagates_after_normal_result
    [nil, Interrupt.new("foreground cancellation")].each do |failure|
      output = StringIO.new
      output.define_singleton_method(:tty?) { true }
      actual_write = output.method(:write)
      cleanup = Interrupt.new("clear display cancellation")
      output.define_singleton_method(:write) do |text|
        raise cleanup if text.start_with?("\r\e[2K")

        actual_write.call(text)
      end
      progress = Netdisco::Progress.new(io: output)
      before = Thread.list
      operation = lambda do
        progress.with_updates do
          progress.tick
          raise failure if failure

          :completed_report
        end
      end
      assert_same failure || cleanup, assert_raises(Interrupt, &operation)
      assert_empty Thread.list - before
      assert_nil progress.output_error
    end
  end

  def test_terminal_clear_and_nonterminal_flush_failures_disable_only_progress
    %i[clear flush].each do |stage|
      output = StringIO.new
      output.define_singleton_method(:tty?) { stage == :clear }
      progress = Netdisco::Progress.new(io: output)
      result = progress.with_updates do
        if stage == :clear
          progress.tick
          output.define_singleton_method(:write) { |*| raise Errno::EIO, "private terminal diagnostic" }
        else
          output.define_singleton_method(:flush) { raise IOError, "private terminal diagnostic" }
          progress.reading_inventory
        end
        :completed_report
      end
      assert_equal :completed_report, result
      assert_equal(stage == :clear ? "Errno::EIO" : "IOError", progress.output_error.fetch(:error_type))
      progress.location("report.json")
    end
  end

  def test_compact_lines_fit_narrow_terminal
    output = StringIO.new
    output.define_singleton_method(:tty?) { true }
    output.define_singleton_method(:winsize) { [24, 40] }
    progress = Netdisco::Progress.new(io: output)
    progress.tick
    output.string.split("\n").each do |line|
      assert_operator line.each_char.sum { |char| char.ord > 255 ? 2 : 1 }, :<, 40
    end
  end

  def test_eta_uses_completed_throughput_and_finishes_at_zero
    output = StringIO.new
    output.define_singleton_method(:tty?) { true }
    progress = Netdisco::Progress.new(io: output)
    clock = 100.0
    progress.define_singleton_method(:monotonic) { clock }
    devices = 10.times.map { |i| Struct.new(:host, :vendor).new("192.0.2.#{i + 1}", :h3c) }
    progress.plan(Struct.new(:ready, :inventory).new(devices, devices), parallel: 2)
    devices.each_with_index do |device, index|
      progress.start(device)
      clock += 2
      progress.result(Netdisco::Outcome.new(device: device, status: :failed, backup: nil,
                                            error_code: :login_timeout, error_type: "Error", duration_ms: 2000))
      assert_includes output.string, "remaining about 00:00:10" if index == 4
    end
    assert_includes output.string, "0.5 devices/s"
    assert_includes output.string, "remaining 00:00:00"
  end

  def test_topology_pending_evidence_is_quiet_by_default_and_explained_in_verbose_mode
    [false, true].each do |verbose|
      output = StringIO.new
      progress = Netdisco::Progress.new(io: output, verbose: verbose)
      device = Struct.new(:host, :vendor).new("192.0.2.1", :h3c)
      progress.operation_plan([device], parallel: 1, label: "拓扑发现/规划")
      progress.start(device)
      progress.operation_result(device: device, status: :unverified, duration_ms: 10,
                                issues: [{ interface: "GE1/0/1", code: :unknown_neighbor_name }])
      if verbose
        assert_includes output.string, "neighbor name missing 1 interfaces"
        assert_includes output.string, "contains unverified interfaces"
      else
        refute_includes output.string, device.host
        assert_includes output.string, "unverified 1 failed 0"
      end
    end
  end

end
