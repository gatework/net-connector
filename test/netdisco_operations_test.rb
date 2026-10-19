# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/net/connector/netdisco/operations"

class NetdiscoOperationsTest < Minitest::Test
  Connector = Net::Connector
  Netdisco = Connector::Netdisco

  # 假设备只记录调用事实，不把测试变成真实配置写入。
  class FakeConnector
    attr_accessor :value, :failure, :close_failure
    attr_reader :calls, :closed

    def initialize(value = Connector::Result.new)
      @value, @calls = value, []
    end

    def execute_script(script)
      @calls << [:execute, script.map(&:text)]
      raise failure if failure

      value
    end

    def sync_interface_descriptions(**options, &formatter)
      @calls << [:sync, options, formatter]
      raise failure if failure

      value
    end

    def plan_interface_descriptions(**options, &formatter)
      @calls << [:plan, options, formatter]
      value
    end

    def apply_interface_descriptions(plan, confirmed:)
      @calls << [:apply, plan, confirmed]
      value
    end

    def close
      @closed = true
      raise close_failure if close_failure
    end
  end

  def setup
    @hosts = %w[192.0.2.1 192.0.2.2]
    @devices = @hosts.map do |host|
      Netdisco::Device.from_row({ "ip" => host, "vendor" => "H3C" }, rules: Netdisco::Rules.new)
    end
    @inventory_calls = @credential_calls = 0
    @connectors = @hosts.to_h { |host| [host, FakeConnector.new] }
    @settings = Netdisco::Settings.new(env: {})
    @operations = operations
  end

  def operations(settings: @settings, inventory: nil, credentials: nil, factory: nil)
    Netdisco::Operations.new(settings: settings,
                            inventory: inventory || lambda { |_snapshot|
                              @inventory_calls += 1
                              @devices
                            },
                            credentials: credentials || lambda { |_device|
                              @credential_calls += 1
                              { username: "operator", password: "private-password" }
                            },
                            connector_factory: factory || ->(device, _options) { @connectors.fetch(device.host) })
  end

  def test_sync_forwards_backend_formatting_and_isolates_connection_cleanup_failure
    formatter = ->(_neighbor) { "custom uplink" }
    @connectors.fetch(@hosts.first).close_failure = IOError.new("private cleanup")
    batch = @operations.sync_interface_descriptions(hosts: @hosts, abbreviate: false, lowercase: true, &formatter)
    assert_equal({ total: 2, succeeded: 1, failed: 1, partial: 1, missing_credentials: 0, callback_errors: 0 }, batch.summary)
    assert_equal [[:sync, { abbreviate: false, lowercase: true }, formatter]], @connectors.fetch(@hosts.last).calls
    assert @connectors.values.all?(&:closed)
    refute_includes JSON.generate(batch.to_h), "private cleanup"
  end

  def test_sync_rejects_a_non_result_without_affecting_another_device
    @connectors.fetch(@hosts.first).value = nil
    batch = @operations.sync_interface_descriptions(hosts: @hosts)
    assert_instance_of TypeError, batch.outcomes.first.error
    assert_equal 1, batch.summary.fetch(:succeeded)
    assert_equal 1, batch.summary.fetch(:failed)
    assert @connectors.values.all?(&:closed)
  end

  def test_sync_empty_targets_report_zero_and_do_not_query_inventory
    batch = @operations.sync_interface_descriptions(hosts: [])
    assert_equal :no_devices, batch.status
    assert_equal 0, batch.summary.fetch(:total)
    assert_equal 0, @inventory_calls
    assert_equal 0, @credential_calls
  end

  def test_sync_preflights_all_targets_and_options_before_connecting
    [-> { @operations.sync_interface_descriptions(hosts: @hosts, lowercase: nil) },
     -> { @operations.sync_interface_descriptions(hosts: [@hosts.first, @hosts.first]) },
     -> { @operations.sync_interface_descriptions(hosts: [@hosts.first, "192.0.2.99"]) }].each do |call|
      assert_raises(ArgumentError, &call)
    end
    @devices[-1] = @devices.last.with(vendor: :palo_alto)
    assert_raises(Connector::UnsupportedOperation) { @operations.sync_interface_descriptions(hosts: @hosts) }
    assert_equal 0, @credential_calls
    assert(@connectors.values.all? { |connector| connector.calls.empty? })
  end

  def test_scripts_parse_once_and_preserve_request_order
    batch = @operations.execute_scripts(scripts: { @hosts.last => "# comment\nshow status\n", @hosts.first => ["show version"] }, confirmed: true)
    assert batch.success?
    assert_equal(@hosts.reverse, batch.outcomes.map { |outcome| outcome.device.host })
    assert_equal [[:execute, ["show status"]]], @connectors.fetch(@hosts.last).calls
    assert @connectors.values.all?(&:closed)
    assert_equal 2, @credential_calls
    assert(batch.outcomes.all? { |outcome| outcome.duration_ms >= 0 })
  end

  def test_all_inputs_fail_before_inventory_or_credentials
    invalid_calls = [
      -> { @operations.execute_scripts(scripts: { @hosts.first => ["show"] }) },
      -> { @operations.execute_scripts(scripts: { @hosts.first => ["show"] }, confirmed: true, parallel: 0) },
      -> { @operations.execute_scripts(scripts: { @hosts.first => ["show"] }, confirmed: true, on_result: Object.new) },
      -> { @operations.execute_scripts(scripts: { @hosts.first => ["show"], @hosts.last => [Object.new] }, confirmed: true) },
      -> { @operations.execute_scripts(scripts: { "2001:db8::1" => [], "2001:db8:0:0::1" => [] }, confirmed: true) },
      -> { @operations.plan_interface_descriptions(hosts: [@hosts.first, @hosts.first]) },
      -> { @operations.plan_interface_descriptions(hosts: @hosts, lowercase: "true") }
    ]
    invalid_calls.each { |call| assert_raises(ArgumentError, Connector::ScriptError, &call) }
    assert_equal 0, @inventory_calls
    assert_equal 0, @credential_calls
    assert(@connectors.values.all? { |connector| connector.calls.empty? })
  end

  def test_unknown_or_nonready_later_target_never_starts_earlier_device
    assert_raises(ArgumentError) do
      @operations.execute_scripts(scripts: { @hosts.first => ["change"], "192.0.2.99" => ["change"] }, confirmed: true)
    end
    @devices[-1] = @devices.last.with(issue: :duplicate_host)
    assert_raises(ArgumentError) do
      @operations.execute_scripts(scripts: @hosts.to_h { |host| [host, ["change"]] }, confirmed: true)
    end
    assert_equal 0, @credential_calls
    assert(@connectors.values.all? { |connector| connector.calls.empty? })
  end

  def test_failed_result_preserves_steps_and_first_error_when_close_fails
    error = Connector::DeviceError.new("private-message", code: :stale_plan, phase: :apply)
    step = Connector::Command::Result.new(command: Connector::Command.new("private-command"), output: "private-output", prompt: "#", duration: 0)
    result = Connector::Result.new(steps: [step], error: error)
    connector = @connectors.fetch(@hosts.first)
    connector.value = result
    connector.close_failure = IOError.new("private-close")
    batch = @operations.execute_scripts(scripts: { @hosts.first => ["change"] }, confirmed: true)
    outcome = batch.outcomes.first
    assert_same result, outcome.value
    assert_same error, outcome.error
    assert outcome.partial?
    summary = JSON.generate(batch.to_h)
    %w[private-message private-command private-output private-close private-password].each { |secret| refute_includes summary, secret }
    refute_includes batch.inspect, "private"
    refute_includes outcome.inspect, "private"
  end

  def test_failed_result_without_steps_is_failed_even_without_an_exception
    result = Connector::Result.new(error: Connector::DeviceError.new("failed"))
    @connectors.fetch(@hosts.first).value = result
    outcome = @operations.execute_scripts(scripts: { @hosts.first => ["change"] }, confirmed: true).outcomes.first
    assert_equal :failed, outcome.status
    assert_same result.error, outcome.error
  end

  def test_successful_result_with_close_failure_is_partial_even_without_steps
    connector = @connectors.fetch(@hosts.first)
    connector.close_failure = IOError.new("closed")
    outcome = @operations.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true).outcomes.first
    assert outcome.partial?
    assert_same connector.value, outcome.value
  end

  def test_exception_in_one_task_does_not_skip_another_device
    connector = @connectors.fetch(@hosts.first)
    connector.failure = IOError.new("failure")
    connector.close_failure = ArgumentError.new("later failure")
    batch = @operations.execute_scripts(scripts: @hosts.to_h { |host| [host, ["change"]] }, confirmed: true)
    assert_equal %i[failed succeeded], batch.outcomes.map(&:status)
    assert_same connector.failure, batch.outcomes.first.error
    assert @connectors.values.all?(&:closed)
  end

  def test_callback_failure_is_separate_safe_summary
    callback = ->(_) { raise IOError, "private-callback" }
    batch = @operations.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true, on_start: callback, on_result: callback)
    assert batch.outcomes.first.success?
    refute batch.success?
    assert_equal 2, batch.callback_errors.size
    assert_equal "IOError", batch.callback_errors.first.fetch(:error_type)
    refute_includes JSON.generate(batch.to_h), "private-callback"
    assert_equal({ total: 1, succeeded: 1, failed: 0, partial: 0, missing_credentials: 0, callback_errors: 2 }, batch.summary)
  end

  # 同一批混合各类普通失败，单线程与并发调度都必须为每台设备交付唯一终态。
  def test_mixed_failures_are_isolated_and_report_balances_every_scheduled_device
    [1, 3].each do |parallel|
      hosts = Array.new(5) { |index| "192.0.2.#{index + 1}" }
      devices = hosts.map { |host| Netdisco::Device.from_row({ "ip" => host, "vendor" => "H3C" }, rules: Netdisco::Rules.new) }
      connectors = hosts.to_h { |host| [host, FakeConnector.new] }
      connectors.fetch(hosts[1]).failure = IOError.new("execution failed")
      connectors.fetch(hosts[2]).close_failure = IOError.new("close failed")
      credentials = ->(device) { device.host == hosts[3] ? nil : { username: "operator" } }
      factory = lambda do |device, _options|
        raise IOError, "connection failed" if device.host == hosts[4]

        connectors.fetch(device.host)
      end
      operation = operations(inventory: ->(_) { devices }, credentials: credentials, factory: factory)
      batch = operation.execute_scripts(scripts: hosts.to_h { |host| [host, ["change"]] }, confirmed: true, parallel: parallel)
      assert_equal(hosts, batch.outcomes.map { |outcome| outcome.device.host })
      assert_equal %i[succeeded failed partial missing_credentials failed], batch.outcomes.map(&:status)
      assert_equal({ total: 5, succeeded: 1, failed: 4, partial: 1, missing_credentials: 1, callback_errors: 0 }, batch.summary)
      assert batch.summary.frozen?
      assert batch.outcomes.frozen?
      assert batch.outcomes.all?(&:frozen?)
      assert_equal batch.summary, batch.to_h.fetch(:summary)
      assert_equal 5, batch.summary.values_at(:succeeded, :failed).sum
      assert_equal 3, connectors.values.count(&:closed)
      assert_equal 0, connectors.fetch(hosts[3]).calls.size
      assert_equal 0, connectors.fetch(hosts[4]).calls.size
      assert_equal "incomplete", JSON.parse(JSON.generate(batch.to_h)).fetch("status")
    end
  end

  def test_failed_task_does_not_interrupt_an_active_sibling_or_queued_task
    started = Queue.new
    release = Queue.new
    host = "192.0.2.3"
    @devices << Netdisco::Device.from_row({ "ip" => host, "vendor" => "H3C" }, rules: Netdisco::Rules.new)
    @connectors[host] = FakeConnector.new
    @connectors.fetch(@hosts.first).define_singleton_method(:execute_script) do |_script|
      started.pop
      release << true
      raise IOError, "one device failed"
    end
    @connectors.fetch(@hosts.last).define_singleton_method(:execute_script) do |_script|
      started << true
      release.pop
      value
    end
    hosts = @hosts + [host]
    batch = @operations.execute_scripts(scripts: hosts.to_h { |target| [target, ["change"]] }, confirmed: true, parallel: 2)
    assert_equal %i[failed succeeded succeeded], batch.outcomes.map(&:status)
    assert_equal({ total: 3, succeeded: 2, failed: 1, partial: 0, missing_credentials: 0, callback_errors: 0 }, batch.summary)
    assert @connectors.values.all?(&:closed)
    assert_equal [[:execute, ["change"]]], @connectors.fetch(host).calls
  end

  def test_empty_batch_report_contains_zero_counts
    batch = @operations.execute_scripts(scripts: {}, confirmed: true)
    assert_equal :no_devices, batch.status
    refute batch.success?
    assert_equal({ total: 0, succeeded: 0, failed: 0, partial: 0, missing_credentials: 0, callback_errors: 0 }, batch.summary)
  end

  def test_interrupt_propagates_after_close_and_is_not_hidden_by_close_failure
    connector = @connectors.fetch(@hosts.first)
    connector.failure = Interrupt.new("stop")
    connector.close_failure = IOError.new("close")
    error = assert_raises(Interrupt) do
      @operations.execute_scripts(scripts: { @hosts.first => ["change"] }, confirmed: true)
    end
    assert_same connector.failure, error
    assert connector.closed
  end

  def test_planning_is_read_only_and_shares_immutable_domain_plans
    original = plan(@hosts.first)
    @connectors.fetch(@hosts.first).value = original
    formatter = ->(_) { "description" }
    batch = @operations.plan_interface_descriptions(hosts: [@hosts.first], &formatter)
    value = batch.plans.fetch(@hosts.first)
    assert batch.success?
    assert_same original, value
    assert value.evidence.frozen?
    assert value.changes.first.neighbor.neighbor_name.frozen?
    assert_equal :plan, @connectors.fetch(@hosts.first).calls.first.first
    assert_same formatter, @connectors.fetch(@hosts.first).calls.first.last
    refute_includes JSON.generate(batch.to_h), "secret-neighbor"
  end

  def test_planning_close_failure_keeps_evidence_but_does_not_auto_approve_it
    @connectors.fetch(@hosts.first).value = plan(@hosts.first)
    @connectors.fetch(@hosts.first).close_failure = IOError.new("close")
    batch = @operations.plan_interface_descriptions(hosts: [@hosts.first])
    assert batch.outcomes.first.partial?
    assert_instance_of Connector::Topology::Plan, batch.outcomes.first.value
    assert_empty batch.plans
  end

  def test_apply_delegates_to_domain_operation_with_fixed_plan_and_confirmation
    original = plan(@hosts.first)
    batch = @operations.apply_interface_descriptions(plans: { @hosts.first => original }, confirmed: true)
    assert batch.success?
    call = @connectors.fetch(@hosts.first).calls.first
    assert_equal :apply, call.first
    assert_equal true, call.last
    assert_same original, call[1]
    assert call[1].changes.frozen?
    assert_equal 1, @connectors.fetch(@hosts.first).calls.size
  end

  def test_all_apply_plans_are_preflighted_before_any_connection
    assert_raises(ArgumentError) do
      @operations.apply_interface_descriptions(plans: { @hosts.first => plan(@hosts.first), @hosts.last => Object.new }, confirmed: true)
    end
    assert_equal 0, @inventory_calls
    wrong_vendor = plan(@hosts.first).with(vendor: :cisco_ios)
    assert_raises(ArgumentError) do
      @operations.apply_interface_descriptions(plans: { @hosts.first => wrong_vendor }, confirmed: true)
    end
    assert_equal 0, @credential_calls
    modified = plan(@hosts.last).with(commands: ["unapproved command"])
    assert_raises(ArgumentError) do
      @operations.apply_interface_descriptions(plans: { @hosts.first => plan(@hosts.first), @hosts.last => modified }, confirmed: true)
    end
    assert_equal 0, @credential_calls
    assert @connectors.values.none?(&:closed)
  end

  def test_unsupported_later_topology_target_is_rejected_before_any_device_session
    @devices[-1] = @devices.last.with(vendor: :palo_alto)
    assert_raises(Connector::UnsupportedOperation) { @operations.plan_interface_descriptions(hosts: @hosts) }
    unsupported = plan(@hosts.last).with(vendor: :palo_alto)
    assert_raises(Connector::UnsupportedOperation) do
      @operations.apply_interface_descriptions(plans: { @hosts.first => plan(@hosts.first), @hosts.last => unsupported }, confirmed: true)
    end
    assert_equal 0, @credential_calls
    assert @connectors.values.none?(&:closed)
  end

  def test_filtered_and_duplicate_inventory_targets_cannot_be_forced_with_explicit_hosts
    @devices[-1] = @devices.last.with(issue: :filtered)
    assert_raises(ArgumentError) { @operations.plan_interface_descriptions(hosts: @hosts) }
    @devices[-1] = @devices.last.with(issue: nil)
    @devices << @devices.first
    assert_raises(ArgumentError) do
      @operations.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true)
    end
    assert_equal 0, @credential_calls
  end

  def test_duplicate_interface_approval_fails_before_any_device_session
    original = plan(@hosts.last)
    first = original.changes.first
    duplicate = first.with(new_description: "conflicting")
    commands = original.commands.dup
    commands.insert(commands.index("return"),
                    *Connector::Topology::InterfaceDescription.commands(interface: first.interface, description: "conflicting", leave: "quit"))
    invalid = original.with(changes: [first, duplicate], commands: commands)
    assert_raises(ArgumentError) do
      @operations.apply_interface_descriptions(plans: { @hosts.first => plan(@hosts.first), @hosts.last => invalid }, confirmed: true)
    end
    assert_equal 0, @credential_calls
    assert(@connectors.values.all? { |connector| connector.calls.empty? && !connector.closed })
  end

  def test_policy_is_fixed_and_credentials_resolved_for_each_device
    seen = []
    defaults = { "NC_PROTOCOL" => "telnet" }
    @settings = Netdisco::Settings.new(env: {}, defaults: defaults)
    credentials = lambda do |device|
      defaults["NC_PROTOCOL"] = "ssh"
      { username: "operator-#{device.host}" }
    end
    factory = lambda do |device, options|
      seen << [options.fetch(:username), options.fetch(:protocol)]
      @connectors.fetch(device.host)
    end
    operation = operations(credentials: credentials, factory: factory)
    assert operation.execute_scripts(scripts: @hosts.to_h { |host| [host, []] }, confirmed: true).success?
    assert_equal @hosts.map { |host| ["operator-#{host}", :telnet] }.sort, seen.sort
  end

  def test_planning_wrong_device_evidence_is_not_accepted
    @connectors.fetch(@hosts.first).value = plan(@hosts.last)
    batch = @operations.plan_interface_descriptions(hosts: [@hosts.first])
    assert_equal :failed, batch.outcomes.first.status
    assert_empty batch.plans
    assert @connectors.fetch(@hosts.first).closed
  end

  def test_configured_parallel_bounds_device_operations
    started = Queue.new
    release = Queue.new
    @settings = Netdisco::Settings.new(env: { "NC_PARALLEL" => "1" })
    @connectors.values.each do |connector|
      connector.define_singleton_method(:execute_script) do |_script|
        started << self
        release.pop
        value
      end
    end
    runner = Thread.new do
      operations.execute_scripts(scripts: @hosts.to_h { |host| [host, []] }, confirmed: true)
    end
    first = started.pop
    assert_equal 0, started.size
    release << true
    second = started.pop
    refute_same first, second
    assert first.closed
    release << true
    assert runner.join(2), "批次应在放行两个串行任务后结束"
    assert runner.value.success?
  ensure
    runner&.kill
    runner&.join
  end

  def test_script_input_changes_during_inventory_do_not_change_commands
    scripts = { @hosts.first => [+"original"] }
    operation = operations(inventory: lambda { |_snapshot|
      scripts.fetch(@hosts.first)[0].replace("mutated")
      @devices
    })
    assert operation.execute_scripts(scripts: scripts, confirmed: true).success?
    assert_equal [[:execute, ["original"]]], @connectors.fetch(@hosts.first).calls
  end

  def test_empty_batch_has_no_device_sessions
    batch = @operations.execute_scripts(scripts: {}, confirmed: true)
    assert_equal :no_devices, batch.status
    refute batch.success?
    assert_equal 0, @credential_calls
    assert_equal 0, @inventory_calls
    assert_empty batch.outcomes
  end

  def test_missing_credentials_is_distinct_from_invalid_resolver_value
    operation = operations(credentials: ->(_) { nil })
    outcome = operation.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true).outcomes.first
    assert_equal :missing_credentials, outcome.status
    assert_nil outcome.error
    assert @connectors.values.none?(&:closed)
    operation = operations(credentials: ->(_) { {} })
    outcome = operation.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true).outcomes.first
    assert_equal :failed, outcome.status
    assert_instance_of ArgumentError, outcome.error
  end

  def test_logs_are_created_only_after_complete_target_preflight
    Dir.mktmpdir do |directory|
      log_directory = File.join(directory, "logs")
      settings = Netdisco::Settings.new(env: {}, overrides: { "NC_LOG_DIRECTORY" => log_directory })
      seen = []
      operation = operations(settings: settings, factory: lambda { |device, options|
        seen << options.fetch(:log_file)
        @connectors.fetch(device.host)
      })
      assert_raises(ArgumentError) do
        operation.execute_scripts(scripts: { @hosts.first => [], "192.0.2.99" => [] }, confirmed: true)
      end
      refute File.exist?(log_directory)
      assert operation.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true).success?
      assert_equal [File.join(log_directory, "192.0.2.1.log")], seen
      assert_equal 0o700, File.stat(log_directory).mode & 0o777
    end
  end

  def test_data_updates_keep_validation_and_immutable_containers
    batch = @operations.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true)
    mutable_time = Time.now
    outcome = batch.outcomes.first.with(started_at: mutable_time)
    assert outcome.started_at.frozen?
    refute_same mutable_time, outcome.started_at
    assert_raises(ArgumentError) { outcome.with(status: :unknown) }
    outcomes = [outcome]
    updated = batch.with(outcomes: outcomes)
    outcomes.clear
    assert_equal 1, updated.outcomes.size
    assert updated.outcomes.frozen?
    assert_raises(ArgumentError) { batch.with(outcomes: [Object.new]) }
    external_plan = plan(@hosts.first)
    outcome = outcome.with(value: external_plan)
    assert_raises(FrozenError) { external_plan.evidence.clear }
    assert_equal 1, outcome.value.evidence.size
    assert outcome.value.evidence.frozen?
    errors = [{ host: +"192.0.2.1", error_type: "IOError" }]
    updated = batch.with(callback_errors: errors)
    errors.first.fetch(:host).replace("192.0.2.99")
    assert_equal "192.0.2.1", updated.callback_errors.first.fetch(:host)
    assert updated.callback_errors.first.fetch(:host).frozen?
  end

  def test_data_updates_cannot_relabel_a_failed_result_as_success
    @connectors.fetch(@hosts.first).value = Connector::Result.new(error: Connector::DeviceError.new("failed"))
    outcome = @operations.execute_scripts(scripts: { @hosts.first => [] }, confirmed: true).outcomes.first
    assert_raises(ArgumentError) { outcome.with(status: :succeeded) }
    assert_raises(ArgumentError) { outcome.with(status: :partial) }
    assert_raises(ArgumentError) { outcome.with(status: :missing_credentials) }
    assert_raises(ArgumentError) { outcome.with(error: IOError.new("different")) }
    assert_raises(ArgumentError) { outcome.with(status: :succeeded, value: nil, error: nil) }
  end

  private

  # 直接构造审批值，验证领域对象与批次共用同一不可变边界。
  def plan(host)
    neighbor = Connector::Topology::Neighbor.new(local_interface: "GigabitEthernet1/0/1", neighbor_name: "secret-neighbor",
                                                 neighbor_interface: "Ethernet1", chassis_id: "chassis", protocol: :lldp)
    change = Connector::Topology::Change.new(interface: "GigabitEthernet1/0/1", old_description: "old", new_description: "new", neighbor: neighbor)
    profile = Connector.vendor_class(:h3c).profile
    context = Struct.new(:host, :profile).new(host, profile)
    context.define_singleton_method(:config_commands) { profile.config_commands }
    strategy = profile.topology_strategy.new(context)
    commands = Connector::Topology::Stages.build(strategy: strategy, host: host, changes: [change]).values.flat_map do |script|
      script.map(&:text)
    end
    Connector::Topology::Plan.new(host: host, vendor: :h3c,
                                 evidence: { "GigabitEthernet1/0/1" => ["secret-neighbor", "Ethernet1", "old"] },
                                 changes: [change], commands: commands)
  end
end
