# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class ScriptOutputBudgetTest < Minitest::Test
  Connector = Net::Connector

  def teardown = @device&.close

  def build(*responses, **options)
    @transport = ConnectorFake.new("router#", *responses)
    @device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit", transport: @transport, **options)
  end

  def test_budget_is_optional_and_rejects_invalid_values_before_io
    assert_nil Connector::Configuration.new.max_script_output_bytes
    assert_equal 1, Connector::Configuration.new(max_script_output_bytes: 1).max_script_output_bytes
    [0, -1, 1.5, Float::INFINITY, "1024", false, true].each do |value|
      assert_raises(ArgumentError) { Connector::Configuration.new(max_script_output_bytes: value) }
    end
    build(*Array.new(10, "response\nrouter#"))
    result = @device.execute_script(Array.new(10) { |index| "show #{index}" })
    assert result.success?
    assert_equal 10, result.steps.size
  end

  def test_exact_budget_can_finish_but_blocks_the_next_send_and_preserves_failure_location
    response = "first\nrouter#"
    build(response, max_script_output_bytes: response.bytesize)
    callbacks = []
    script = Connector::Script.parse("show first\nshow second\n", name: "fixture-script")
    result = @device.execute_script(script) { |step| callbacks << step.command.text }
    assert_budget_error(result, "show second")
    assert_equal "fixture-script", result.error.source
    assert_equal 2, result.error.line
    assert_equal [response], result.steps.map(&:output)
    assert_equal ["show first"], callbacks
    assert_equal ["show first\n"], @transport.writes
    assert @transport.closed?
    @transport.events.concat(["router#", response])
    assert @device.execute_command("show fresh").success?
    assert_equal ["show first\n", "show fresh\n"], @transport.writes
  end

  def test_post_response_limit_keeps_the_completed_step_and_stops_hooks_callbacks_and_following_commands
    first = "first\nrouter#"
    second = "second\nrouter#"
    build(first, second, max_script_output_bytes: first.bytesize + second.bytesize - 1)
    hooks = []
    callbacks = []
    @device.define_singleton_method(:after_command) { |command, *_| hooks << command.text }
    result = @device.execute_script(["first", "second", "never"]) { |step| callbacks << step.command.text }
    assert_budget_error(result, "second")
    assert_equal [first, second], result.steps.map(&:output)
    assert_equal ["first"], hooks
    assert_equal ["first"], callbacks
    assert_equal ["first\n", "second\n"], @transport.writes
    assert_includes result.error.message, "may have executed"
  end

  def test_budget_counts_bytes_and_uncaptured_interactions
    build("ab--Next--", "cd\nrouter#", max_script_output_bytes: "abcd\nrouter#".bytesize)
    command = Connector::Command.new("show", interactions: [Connector::Interaction.new(/--Next--/, " ", capture: false)])
    result = @device.execute_script([command, "never"])
    assert_budget_error(result, "show")
    assert_equal "abcd\nrouter#", result.steps.first.output
    assert_equal ["show\n", " "], @transport.writes
    @device.close
    text = "名\nrouter#"
    build(text, max_script_output_bytes: text.length)
    result = @device.execute_command("show")
    assert_budget_error(result, "show")
    assert_equal text.b, result.steps.first.output
  end

  def test_before_batch_query_consumes_budget_before_the_first_script_command
    response = "probe\nrouter#"
    build(response, max_script_output_bytes: response.bytesize)
    @device.define_singleton_method(:before_batch) { |execution| execution.execute_command("probe") }
    result = @device.execute_command("never")
    assert_budget_error(result, "never")
    assert_empty result.steps
    assert_equal ["probe\n"], @transport.writes
  end

  def test_prompt_callback_queries_are_counted_before_sending_the_outer_command
    response = "probe\nrouter#"
    build(response, max_script_output_bytes: response.bytesize)
    execution = nil
    @device.define_singleton_method(:prepare_command) { |command, current| execution = current; command }
    prompt = lambda do |command|
      execution.execute_command("probe") if command.text == "main"
      /router#\z/
    end
    result = @device.execute_operation(Connector::Script.new(["main"]), name: :fixture, prompt: prompt)
    assert_budget_error(result, "main")
    assert_empty result.steps
    assert_equal ["probe\n"], @transport.writes
  end

  def test_prepare_and_after_command_queries_share_the_same_budget
    %i[prepare_command after_command].each do |hook|
      @device&.close
      response = "probe\nrouter#"
      replies = hook == :prepare_command ? [response] : [response, response]
      build(*replies, max_script_output_bytes: response.bytesize + (hook == :prepare_command ? -1 : 1))
      @device.define_singleton_method(hook) { |*args| args.last.execute_command("probe"); args.first }
      result = @device.execute_script(["main", "never"])
      assert_budget_error(result, "probe")
      assert_equal(hook == :prepare_command ? [] : [response], result.steps.map(&:output))
      assert_equal(hook == :prepare_command ? ["probe\n"] : ["main\n", "probe\n"], @transport.writes)
    end
  end

  def test_each_script_has_a_new_budget_even_within_one_operation_lease
    response = "response\nrouter#"
    build(response, response, max_script_output_bytes: response.bytesize)
    results = @device.with_operation(:fixture) { [@device.execute_command("first"), @device.execute_command("second")] }
    assert results.all?(&:success?)
    assert_equal [response, response], results.map(&:output)
    assert_equal ["first\n", "second\n"], @transport.writes
  end

  def test_a_hook_cannot_swallow_an_over_budget_query_and_report_script_success
    response = "response\nrouter#"
    build(response, response, max_script_output_bytes: response.bytesize + 1)
    @device.define_singleton_method(:after_command) do |_, _, execution|
      execution.execute_command("probe")
    rescue Connector::ScriptOutputLimitExceeded
      nil
    end
    result = @device.execute_command("main")
    assert_budget_error(result, "probe")
    assert_equal [response], result.steps.map(&:output)
    assert_equal ["main\n", "probe\n"], @transport.writes
  end

  def test_single_response_limit_still_applies_first
    build(("x" * 64) + "\nrouter#", max_output_bytes: 32, max_script_output_bytes: 128)
    result = @device.execute_script(["large", "never"])
    assert_instance_of Connector::OutputLimitExceeded, result.error
    assert_equal :output_limit_exceeded, result.error.code
    assert_empty result.steps
    assert_equal ["large\n"], @transport.writes
  end

  def test_failed_sensitive_collection_preserves_complete_output_without_diagnostic_content
    secret = "fixture-#{SecureRandom.hex(12)}"
    body = "service opaque #{secret}\nrouter#"
    build("router#", body, max_script_output_bytes: 8)
    result = @device.running_config
    assert_budget_error(result, "show running-config")
    assert_equal ["terminal length 0", "show running-config"], (result.steps.map { |step| step.command.text })
    assert_equal body, result.steps.last.output
    assert_nil result.config
    refute_includes result.error.full_message, secret
    assert_nil result.error.cause
    assert_nil result.error.underlying
    assert_includes ["", "[REDACTED]"], result.error.output
  end

  def test_completed_transfer_evidence_survives_a_post_response_budget_failure
    @transport = ConnectorFake.new("fw#", "Export ok,target file name backup.dat\nfw#")
    @device = Connector.build(:hillstone, host: "192.0.2.1", username: "audit", transport: @transport, max_script_output_bytes: 8)
    error = assert_raises(Connector::TftpCompletionError) { @device.tftp_backup(host: "192.0.2.10", path: "backup.dat") }
    assert_equal "backup.dat", error.receipt.path
    assert_equal :device_reported, error.receipt.verification
    assert_equal "Net::Connector::ScriptOutputLimitExceeded", error.underlying_type
    assert_equal 1, @transport.writes.size
    assert @transport.closed?
  end

  private

  def assert_budget_error(result, command)
    assert_instance_of Connector::ScriptOutputLimitExceeded, result.error
    assert_equal :script_output_limit_exceeded, result.error.code
    assert_equal :script, result.error.phase
    assert_equal command, result.error.command
    assert_nil result.error.cause
    assert_raises(Connector::ScriptOutputLimitExceeded) { result.value! }
  end
end
