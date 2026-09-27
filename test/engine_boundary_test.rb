# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "logger"
require "stringio"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class EngineBoundaryTest < Minitest::Test
  Connector = Net::Connector

  def test_invalid_connection_settings_fail_before_creating_a_transport
    invalid = [
      { port: 0 }, { port: 65_536 }, { port: "22" }, { max_output_bytes: 0 },
      { logger: Object.new }, { logger: Logger.new(StringIO.new), log_file: "unused.log" },
      { host_key_policy: :replace }, { challenges: [Object.new] }, { host: 123 },
      { password: "first\nsecond" }, { enable_password: "first\x00second" },
      { login_timeout: nil }, { telnet_fallback: "true" }, { protocol: :unknown }
    ]
    invalid.each do |options|
      assert_raises(ArgumentError, options.keys.inspect) { Connector::Configuration.new(**options) }
    end
    [{ host: "-oProxyCommand=bad", username: "operator" },
     { host: "192.0.2.1", username: "bad user" }].each do |options|
      assert_raises(ArgumentError) { Connector::Configuration.new(**options).validate_endpoint! }
    end
  end

  def test_ssh_arguments_keep_host_key_policy_and_credentials_separate
    configuration = config(password: "replace-me", port: 2222, known_hosts: "tmp/known_hosts",
                           host_key_policy: :accept_new, login_timeout: 0.5)
    transport = Connector::Transports.build(configuration)
    arguments = transport.argv
    assert_equal "ssh", arguments.first
    assert_includes arguments, "StrictHostKeyChecking=accept-new"
    assert_includes arguments, "ConnectTimeout=1"
    assert_includes arguments, "UserKnownHostsFile=#{File.expand_path("tmp/known_hosts")}"
    assert_equal ["-p", "2222", "-l", "operator", "192.0.2.1"], arguments.last(5)
    refute_includes arguments.join(" "), "replace-me"

    strict = Connector::Transports::Ssh.new(config)
    assert_includes strict.argv, "StrictHostKeyChecking=yes"
    refute_includes strict.argv, "-p"
    assert_equal :ssh, strict.protocol
  end

  def test_telnet_fallback_never_inherits_the_ssh_port
    ssh = Connector::Transports::Ssh.new(config(port: 2222))
    telnet = ssh.as_telnet
    assert_equal :telnet, telnet.protocol
    assert_equal ["telnet", "-l", "operator", "192.0.2.1"], telnet.argv
    direct = Connector::Transports.build(config(protocol: :telnet, port: 2323))
    assert_equal "2323", direct.argv.last
  end

  def test_host_key_replacement_uses_only_the_explicit_host_and_known_hosts
    [nil, 2222].each do |port|
      transport = Connector::Transports::Ssh.new(config(port: port, known_hosts: "tmp/known_hosts"))
      [true, false].each do |success|
        process_status = Struct.new(:success?).new(success)
        run = lambda do |*arguments|
          host = port ? "[192.0.2.1]:2222" : "192.0.2.1"
          assert_equal ["ssh-keygen", "-f", File.expand_path("tmp/known_hosts"), "-R", host], arguments
          ["", process_status]
        end
        Open3.stub(:capture2e, run) do
          if success
            transport.replace_host_key
          else
            assert_raises(IOError) { transport.replace_host_key }
          end
        end
      end
    end
  end

  def test_recovery_requires_explicit_configuration_and_a_supported_failure
    arguments = ["-o", "HostKeyAlgorithms=+ssh-rsa"]
    configuration = config(telnet_fallback: true, legacy_ssh: true, host_key_policy: :replace,
                           known_hosts: "tmp/known_hosts")
    transport = Connector::Transports::Ssh.new(configuration)
    recovery = Connector::Recovery.new(configuration, legacy_arguments: arguments)
    error = ->(code) { Connector::ConnectionError.new("connection failed", code: code) }
    assert_instance_of Connector::Transports::Telnet, recovery.recover(error.call(:connection_refused), transport)
    assert_equal arguments, recovery.recover(error.call(:rsa_too_small), transport).legacy_arguments
    assert_equal ["-c", "des"], recovery.recover(error.call(:unsupported_cipher), transport).legacy_arguments
    replacements = 0
    transport.stub(:replace_host_key, -> { replacements += 1 }) do
      assert_same transport, recovery.recover(error.call(:host_key_changed), transport)
    end
    assert_equal 1, replacements
    assert_nil recovery.recover(error.call(:authentication_failed), transport)
    %i[connection_refused host_key_changed rsa_too_small].each do |code|
      assert_nil recovery.recover(error.call(code), Object.new)
      disabled = Connector::Recovery.new(config, legacy_arguments: arguments)
      assert_nil disabled.recover(error.call(code), transport)
    end
  end

  def test_connection_recovery_closes_the_failed_transport_and_retries_only_once
    ["router#", "Connection refused"].each do |response|
      first = ConnectorFake.new("Connection refused")
      second = ConnectorFake.new(response)
      recoveries = 0
      [first, second].each do |transport|
        transport.define_singleton_method(:as_telnet) { recoveries += 1; second }
      end
      device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator",
                               transport: first, telnet_fallback: true)
      if response == "router#"
        device.connect
        assert device.connected?
      else
        failure = assert_raises(Connector::ConnectionError) { device.connect }
        assert_equal :connection_refused, failure.code
        assert second.closed?
      end
      assert_equal 1, recoveries
      assert_equal 1, first.closes
      assert_equal 1, second.opens
      assert_empty first.writes
      assert_empty second.writes
    ensure
      device&.close
    end
  end

  def test_unknown_host_confirmation_obeys_host_key_policy
    %i[strict accept_new].each do |policy|
      transport = ConnectorFake.new("Continue connecting (yes/no/[fingerprint])? ", "router#")
      device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator",
                               transport: transport, host_key_policy: policy)
      if policy == :strict
        error = assert_raises(Connector::ConnectionError) { device.connect }
        assert_equal :host_key_untrusted, error.code
        assert_empty transport.writes
        assert transport.closed?
      else
        device.connect
        assert_equal ["yes\n"], transport.writes
      end
    ensure
      device&.close
    end
  end

  def test_terminal_rendering_handles_fragmented_cursor_and_title_sequences
    examples = {
      "ab\a\x01\t \n" => "ab\n",
      "abc\e[2DX" => "aXc",
      "abc\e[GX" => "Xbc",
      "a\e[2CX" => "a  X",
      "abc\e[2G\e[K" => "a",
      "abc\e[2G\e[1KX" => " Xc",
      "abc\e[2KX" => "X",
      "abc\e[3K" => "abc",
      "a\e]window title\aB" => "aB",
      "a\e]window\eXtitle\e\\B" => "aB",
      "a\eZB" => "aB",
      "a\e[\x01B" => "aB",
      "\xFF\n".b => "\\xFF\n"
    }
    examples.each do |input, expected|
      output = StringIO.new("".b)
      renderer = Connector::TerminalRenderer.new(output)
      input.each_byte { |byte| renderer.write(byte.chr) }
      renderer.finish
      assert_equal expected.b, output.string, input.inspect
    end
  end

  def test_terminal_limits_reject_unbounded_cursor_and_escape_sequences
    assert_raises(ArgumentError) { Connector::TerminalRenderer.new(Object.new) }
    assert_raises(ArgumentError) { Connector::TerminalRenderer.new(StringIO.new, max_line_bytes: 0) }
    ["abcde", "\e[99CX"].each do |input|
      renderer = Connector::TerminalRenderer.new(StringIO.new, max_line_bytes: 4)
      assert_raises(Connector::OutputLimitExceeded) { renderer.write(input) }
    end
    renderer = Connector::TerminalRenderer.new(StringIO.new)
    assert_raises(Connector::OutputLimitExceeded) { renderer.write("\e[" + ("1" * 65)) }
  end

  def test_invalid_interaction_rules_are_rejected_before_execution
    [[//, "yes"], [/prompt/, nil]].each do |pattern, response|
      assert_raises(ArgumentError) { Connector::Interaction.new(pattern, response) }
    end
    [{ limit: 0 }, { sensitive: "yes" }, { capture: nil }].each do |options|
      assert_raises(ArgumentError) { Connector::Interaction.new(/prompt/, "yes", **options) }
    end
  end

  def test_error_output_is_redacted_before_both_truncation_paths
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator",
                             password: "replace-me", transport: ConnectorFake.new)
    session = device.instance_variable_get(:@session)
    examples = {
      "" => "", "short" => "short", "a" * 4096 => "a" * 4096,
      "prefix" + ("a" * 4090) + "replace-me" + "tail" => ("a" * 4082) + "[REDACTED]tail",
      "replace-me" + ("a" * 4094) + "!" => "]" + ("a" * 4094) + "!"
    }
    examples.each do |output, expected|
      created = session.build_error(Connector::DeviceError, "failed", phase: :command, output: output)
      normalized = session.normalize_error(Connector::DeviceError.new("failed", output: output), phase: :command)
      [created, normalized].each do |error|
        assert_equal expected, error.output
        assert_operator error.output.bytesize, :<=, 4096
        refute_includes error.output, "replace-me"
      end
    end
  ensure
    device&.close
  end

  private

  def config(**options)
    Connector::Configuration.new(host: "192.0.2.1", username: "operator", **options)
  end
end
