# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class OutputSeparatorTest < Minitest::Test
  Connector = Net::Connector

  def test_result_output_does_not_insert_the_process_separator
    command = Connector::Command.new("show status")
    steps = %w[first second].map do |output|
      Connector::Command::Result.new(command: command, output: output, prompt: nil, duration: 0)
    end
    output = with_separator { Connector::Result.new(steps: steps).output }
    assert_equal "firstsecond".b, output
  end

  def test_fragmented_and_paginated_responses_preserve_device_bytes
    transport = ConnectorFake.new("router#", "first", "--More--", "second\nrouter#")
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
    result = with_separator { device.execute_command("show status") }
    assert result.success?, result.error.inspect
    assert_equal "firstsecond\nrouter#", result.steps.first.output
    assert_equal ["show status\n", " "], transport.writes
  ensure
    device&.close
  end

  def test_timeout_diagnostics_preserve_partial_device_bytes
    transport = ConnectorFake.new("router#", "first", "second", :timeout)
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
    result = with_separator { device.execute_command("show status") }
    assert_instance_of Connector::CommandTimeout, result.error
    assert_equal "firstsecond", result.error.output
    assert transport.closed?
  ensure
    device&.close
  end

  def test_invalid_utf8_diagnostics_do_not_insert_separator_between_bytes
    rendered = with_separator { Connector::Terminal::Renderer.render("\xe3\x81".b) }
    assert_equal "\\xE3\\x81", rendered
  end

  def test_known_hosts_merge_preserves_exact_lines
    Dir.mktmpdir do |directory|
      key_path = File.join(directory, "key")
      _output, status = Open3.capture2e("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key_path)
      assert status.success?
      key = File.read(key_path + ".pub").split.first(2).join(" ")
      path = File.join(directory, "known_hosts")
      original = "192.0.2.2 #{key}\n"
      addition = "192.0.2.1 #{key}\n"
      File.write(path, original)
      configuration = Connector::Configuration.new(host: "192.0.2.1", username: "operator", known_hosts: path)
      entry = Connector::KnownHosts.new(configuration)
      File.open(entry.path, "a") { |file| file.write(addition) }
      with_separator { entry.commit }
      assert_equal original + addition, File.binread(path)
    ensure
      entry&.close
    end
  end

  private

  def with_separator
    previous, verbosity = $,, $VERBOSE
    $VERBOSE = nil
    $, = "unexpected-separator"
    yield
  ensure
    $, = previous
    $VERBOSE = verbosity
  end
end
