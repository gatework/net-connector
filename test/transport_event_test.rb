# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class TransportEventTest < Minitest::Test
  Connector = Net::Connector

  def test_event_snapshots_mutable_input_as_binary_without_freezing_the_source
    before, match = +"中文", +"router#"
    event = Connector::Event.new(index: 0, before: before, match: match)
    before.replace("overwritten")
    match.clear
    assert_equal "中文".b, event.before
    assert_equal "router#".b, event.match
    assert_equal Encoding::BINARY, event.before.encoding
    assert_equal Encoding::BINARY, event.match.encoding
    assert_raises(FrozenError) { event.before.replace("changed") }
    assert_raises(FrozenError) { event.index = 1 }
  end

  def test_reused_transport_buffer_does_not_overwrite_previous_chunks
    buffer = +""
    chunks = ["中文", "\xff".b].map do |text|
      lambda do |patterns, _timeout|
        buffer.replace(text)
        Connector::Event.new(index: patterns.size, match: buffer)
      end
    end
    transport = ConnectorFake.new("router#", *chunks, "router#")
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
    result = device.execute_command("show status")
    assert result.success?, result.error.inspect
    assert_equal "中文".b + "\xffrouter#".b, result.output
    assert_equal ["show status\n"], transport.writes
  ensure
    device&.close
  end

  def test_invalid_byte_fields_are_rejected_at_the_transport_boundary
    [{ before: nil }, { match: [] }, { before: 1 }].each do |fields|
      assert_raises(ArgumentError) { Connector::Event.new(index: 0, **fields) }
    end
  end

  def test_timeout_keeps_previous_chunks_when_transport_reuses_its_buffer
    buffer = +""
    first = lambda do |patterns, _timeout|
      buffer.replace("first")
      Connector::Event.new(index: patterns.size, match: buffer)
    end
    last = lambda do |*_|
      buffer.replace("last")
      Connector::Event.new(before: buffer, error: :timeout)
    end
    transport = ConnectorFake.new("router#", first, last)
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
    result = device.execute_script(["show first", "must not run"])
    assert_instance_of Connector::CommandTimeout, result.error
    assert_equal "firstlast", result.error.output
    assert_empty result.steps
    assert_equal ["show first\n"], transport.writes
    assert transport.closed?
  ensure
    device&.close
  end

  def test_timeout_retains_binary_partial_output_and_original_error
    original = IOError.new("read failed")
    event = Connector::Event.new(before: "中文", error: original)
    refute event.matched?
    assert_nil event.index
    assert_same original, event.error
    assert_equal "中文".b, event.before
  end
end
