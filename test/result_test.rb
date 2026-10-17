# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class ResultTest < Minitest::Test
  Connector = Net::Connector

  def test_output_preserves_mixed_encoding_bytes_in_step_order
    outputs = ["中文\n", "\xff\x00".b, "末尾".encode(Encoding::UTF_16LE)]
    result = Connector::Result.new(steps: outputs.map { |output| step(output: output) })
    assert_equal outputs.flat_map(&:bytes), result.output.bytes
    assert_equal Encoding::BINARY, result.output.encoding
    assert_equal result.output, result.value!
  end

  def test_output_is_a_mutable_detached_binary_string_for_every_step_count
    [[], [""], ["中文"], ["", ""], ["first", "second"]].each do |outputs|
      steps = outputs.map { |output| step(output: output) }
      result = Connector::Result.new(steps: steps)
      output = result.output
      assert_equal Encoding::BINARY, output.encoding
      refute_predicate output, :frozen?
      output.replace("changed")
      assert_equal outputs.join.b, result.output
      assert_equal outputs, steps.map(&:output)
    end
  end

  def test_failed_result_retains_mixed_encoding_completed_output
    error = Connector::DeviceError.new("failed")
    result = Connector::Result.new(steps: [step(output: "中文"), step(output: "\xff".b)], error: error)
    assert_equal "中文".b + "\xff".b, result.output
    assert_same error, assert_raises(Connector::DeviceError) { result.value! }
  end

  def test_command_result_rejects_invalid_fields_before_use
    invalid = [{ command: "show status" }, { output: nil }, { output: [] }, { prompt: 1 },
               { duration: nil }, { duration: "1" }, { duration: -1 }, { duration: Float::NAN },
               { duration: Float::INFINITY }, { duration: Complex(1, 0) }]
    invalid.each { |fields| assert_raises(ArgumentError, fields.keys.inspect) { step(**fields) } }
  end

  def test_command_result_accepts_finite_real_durations_and_optional_prompt
    [0, 0.25, Rational(1, 4)].each do |duration|
      result = step(duration: duration, prompt: nil)
      assert_equal duration, result.duration
      assert_nil result.prompt
      assert_match(/bytes=6 duration=/, result.inspect)
    end
  end

  def test_command_result_snapshots_text_without_freezing_caller_strings
    output, prompt = +"status", +"router#"
    result = step(output: output, prompt: prompt)
    output.replace("changed")
    prompt.clear
    assert_equal "status", result.output
    assert_equal "router#", result.prompt
    assert_predicate result.output, :frozen?
    assert_predicate result.prompt, :frozen?
    assert_predicate result, :frozen?
  end

  private

  def step(**fields)
    Connector::Command::Result.new(**{ command: Connector::Command.new("show status"), output: "status",
                                    prompt: "router#", duration: 0.01 }.merge(fields))
  end
end
