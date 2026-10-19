# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class PrepareCommandTest < Minitest::Test
  C = Net::Connector

  def teardown
    @device&.close
  end

  # 错误扩展不能先发送替代文本再因结果类型不符丢失执行回执。
  def test_invalid_preparation_is_rejected_before_sending_and_keeps_original_location
    ["description private-replacement", false, Object.new, 7].each do |invalid|
      build("changed\nrouter#")
      @device.define_singleton_method(:prepare_command) { |_, _| invalid }
      command = C::Command.new("description requested", source: "reviewed.cfg", line: 9)
      result = @device.execute_script([command])

      assert_empty @transport.writes
      assert_instance_of C::ScriptError, result.error
      assert_equal :script_error, result.error.code
      assert_equal "reviewed.cfg", result.error.source
      assert_equal 9, result.error.line
      assert_equal "description requested", result.error.command
      assert_empty result.steps
      refute_includes [result.error.message, result.error.output, result.error.command,
                       result.error.underlying&.message].join, "private-replacement"
    end
  end

  def test_invalid_preparation_preserves_previously_completed_commands
    build("completed first\nrouter#", "changed\nrouter#")
    @device.define_singleton_method(:prepare_command) do |command, _|
      command.text == "show first" ? command : "description rejected"
    end
    result = @device.execute_script(["show first", "description second", "never"])

    assert_equal ["show first\n"], @transport.writes
    assert_instance_of C::ScriptError, result.error
    assert_equal ["show first"], (result.steps.map { |step| step.command.text })
    assert_equal "completed first\nrouter#", result.steps.fetch(0).output
  end

  def test_nil_skips_only_that_command_and_a_replacement_keeps_its_metadata
    build("replacement completed\nrouter#")
    replacement = nil
    @device.define_singleton_method(:prepare_command) do |command, _|
      replacement = command.with_text("show replacement") unless command.text == "skip"
    end
    original = C::Command.new("show requested", source: "reviewed.cfg", line: 11, timeout: 2,
                              sensitive: true, output_sensitive: true)
    result = @device.execute_script(["skip", original])

    assert result.success?, result.error.inspect
    assert_equal ["show replacement\n"], @transport.writes
    assert_equal 1, result.steps.size
    actual = result.steps.fetch(0).command
    assert_same replacement, actual
    assert_equal "reviewed.cfg", actual.source
    assert_equal 11, actual.line
    assert_equal 2, actual.timeout
    assert actual.sensitive?
    assert actual.output_sensitive?
  end

  private

  def build(*responses)
    @device&.close
    @transport = ConnectorFake.new("router#", *responses)
    @device = C.build(:cisco_ios, host: "192.0.2.1", username: "audit", transport: @transport)
  end
end
