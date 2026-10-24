# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "json"
require_relative "../lib/net/connector/netdisco/ssh/archive/protocol"

class SshArchiveProtocolTest < Minitest::Test
  Protocol = Net::Connector::Netdisco::SSH::Archive::Protocol
  Failure = Net::Connector::Netdisco::Tftp::Archive::Failure

  def test_control_body_and_trailer_can_share_one_read_without_reinterpreting_binary
    body = "\0\xff\n{\"phase\":\"complete\"}\n".b
    with_protocol(frame("archived") + body + frame("delivered") + frame("complete")) do |protocol, sink, reader|
      assert_equal "archived", protocol.expect_phase("archived").fetch("phase")
      chunks = []
      protocol.read_payload(body.bytesize) { |chunk| chunks << chunk }
      assert_equal body, chunks.join.b
      assert_equal "complete", protocol.expect_phase("complete").fetch("phase")
      protocol.send_frame(action: "cleanup", sha256: "digest")
      assert_equal({ "action" => "cleanup", "sha256" => "digest" }, JSON.parse(sink.string))
      refute reader.closed?
      refute sink.closed?
    end
  end

  def test_fragmented_headers_and_large_binary_payload_are_delivered_in_bounded_chunks
    body = ("x\xff\n".b * 50_000)
    response = frame("archived") + body + frame("delivered")
    fragments = [response.byteslice(0, 3), response.byteslice(3, 9), response.byteslice(12..)]
    with_protocol(response, fragments: fragments) do |protocol|
      protocol.expect_phase("archived")
      chunks = []
      protocol.read_payload(body.bytesize) { |chunk| chunks << chunk }
      assert_equal body, chunks.join.b
      assert(chunks.all? { |chunk| (1..65_536).cover?(chunk.bytesize) })
      assert_operator chunks.size, :>=, 3
    end
  end

  def test_control_frames_reject_excess_length_wrong_shape_error_and_wrong_phase
    responses = ["x" * 16_385, "{}" + (" " * 16_383) + "\n", "[]\n", "null\n", "true\n",
                 "{\"ok\":false,\"phase\":\"ready\"}\n", frame("other"), "{bad}\n", ""]
    responses.each do |response|
      with_protocol(response) { |protocol| assert_raises(Failure) { protocol.expect_phase("ready") } }
    end
  end

  def test_payload_length_must_be_a_positive_bounded_integer
    [0, -1, true, "1", 1.5, 67_108_865].each do |length|
      with_protocol(frame("archived")) do |protocol|
        protocol.expect_phase("archived")
        assert_raises(Failure) { protocol.read_payload(length) { flunk "invalid body delivered" } }
      end
    end
  end

  def test_truncated_extra_and_unconfirmed_payloads_are_rejected
    ["ab", "abc", "abcd" + frame("delivered"), "abc" + frame("complete")].each do |body|
      with_protocol(frame("archived") + body) do |protocol|
        protocol.expect_phase("archived")
        assert_raises(Failure) { protocol.read_payload(3) { |_chunk| } }
      end
    end
  end

  def test_payload_and_trailer_share_the_archived_deadline_even_when_buffered
    with_protocol(frame("archived") + "x" + frame("delivered"), timeout: 0.25) do |protocol|
      protocol.expect_phase("archived")
      delivered = 0
      assert_raises(Failure) do
        protocol.read_payload(1) do |chunk|
          delivered += chunk.bytesize
          sleep 0.35
        end
      end
      assert_equal 1, delivered
    end
  end

  private

  def frame(phase)
    (JSON.generate(ok: true, phase: phase) + "\n").b
  end

  def with_protocol(response, fragments: [response], timeout: 2)
    reader, writer = IO.pipe
    sink = StringIO.new
    producer = Thread.new do
      fragments.each { |part| writer.write(part) }
    rescue IOError, Errno::EPIPE
      nil
    ensure
      writer.close unless writer.closed?
    end
    yield Protocol.new(sink, reader, timeout: timeout), sink, reader
  ensure
    reader&.close unless reader&.closed?
    producer&.kill if producer&.alive?
    producer&.join
  end
end
