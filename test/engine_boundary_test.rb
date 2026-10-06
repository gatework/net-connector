# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "logger"
require "stringio"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class EngineBoundaryTest < Minitest::Test
  Connector = Net::Connector

  def test_open_block_forwarding_preserves_break_and_closes_transport
    transport = ConnectorFake.new("router#")
    returned = Connector.open(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport) do |device|
      assert device.connected?
      break :cancelled
    end
    assert_equal :cancelled, returned
    assert_equal 1, transport.closes
  end

  def test_login_hook_failure_releases_transport_and_allows_a_fresh_connection
    [RuntimeError, Interrupt].each do |failure_class|
      attempts = 0
      connector_class = Class.new(Connector::Base) do
        profile { prompts { login(/router#\z/); command(/router#\z/) } }
        define_method(:after_login) do |_session, _response|
          attempts += 1
          raise failure_class, "login hook failed" if attempts == 1
        end
        protected :after_login
      end
      transport = ConnectorFake.new("router#", "router#", "done\nrouter#")
      device = connector_class.new(host: "192.0.2.1", username: "operator", transport: transport)
      error = assert_raises(failure_class == Interrupt ? Interrupt : Connector::InternalError) { device.connect }
      assert_equal :login, error.phase if error.is_a?(Connector::Error)
      assert_nil error.cause
      assert transport.closed?
      assert_empty transport.writes
      assert_equal 1, attempts
      assert device.execute_command("show status").success?
      assert_equal 2, attempts
      assert_equal 2, transport.opens
      assert_equal ["show status\n"], transport.writes
    ensure
      device&.close
    end
  end

  def test_operation_finalizer_preserves_return_values_and_session_ownership
    [nil, false, :completed].each do |value|
      transport = ConnectorFake.new("router#", "done\nrouter#", "next\nrouter#")
      device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
      script = Connector::Script.new(["show status"])
      returned = device.execute_operation(script, name: :probe, privilege: false) do |result|
        assert_equal ["show status"], (result.steps.map { |step| step.command.text })
        nested = device.execute_command("must not run")
        assert_instance_of Connector::SessionBusy, nested.error
        value
      end
      assert_same value, returned
      assert device.execute_command("show next").success?
      assert_equal ["show status\n", "show next\n"], transport.writes
    ensure
      device&.close
    end
  end

  def test_operation_finalizer_throw_closes_session_and_releases_lock
    transport = ConnectorFake.new("router#", "done\nrouter#", "router#", "next\nrouter#")
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport)
    returned = catch(:cancel) do
      device.execute_operation(Connector::Script.new(["show status"]), name: :probe, privilege: false) do
        throw :cancel, :cancelled
      end
    end
    assert_equal :cancelled, returned
    assert transport.closed?
    assert device.execute_command("show next").success?
    assert_equal 2, transport.opens
    assert_equal ["show status\n", "show next\n"], transport.writes
  ensure
    device&.close
  end

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

  def test_host_key_replacement_requires_explicit_policy
    transport = Connector::Transports::Ssh.new(config(known_hosts: "tmp/known_hosts"))
    assert_raises(IOError) { transport.replace_host_key }
    enabled = Connector::Transports::Ssh.new(config(known_hosts: "tmp/known_hosts", host_key_policy: :replace))
    assert enabled.replace_host_key
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
      "" => "",
      "status complete  " => "status complete",
      "device\x7f" => "device\x7f",
      "ab\a\x01\t \n" => "ab\n",
      "abc\e[2DX" => "aXc",
      "abcdef\rXY" => "XYcdef",
      "abc\bXYZ" => "abXYZ",
      "abc\e[GX" => "Xbc",
      "a\e[2CX" => "a  X",
      "abc\e[2G\e[K" => "a",
      "abc\e[2G\e[1KX" => " Xc",
      "\e[1K名称" => "名称",
      "abc\e[9G\e[1K名称" => "        名称",
      "\e[1K\xFF".b => "\\xFF",
      "abc\e[2KX" => "X",
      "abc\e[3K" => "abc",
      "a\e]window title\aB" => "aB",
      "a\e]window\eXtitle\e\\B" => "aB",
      "a\eZB" => "aB",
      "a\e[\x01B" => "aB",
      "\xFF\n".b => "\\xFF\n",
      "名称 \t\r\nnext \t\nfinal\t" => "名称\nnext\nfinal"
    }
    examples.each do |input, expected|
      [1, 2, 7, [input.bytesize, 1].max].uniq.each do |chunk_size|
        output = StringIO.new("".b)
        renderer = Connector::TerminalRenderer.new(output)
        input.bytes.each_slice(chunk_size) { |bytes| renderer.write(bytes.pack("C*")) }
        renderer.finish
        assert_equal expected.b, output.string, "#{input.inspect} / #{chunk_size} bytes"
      end
      assert_equal expected.b, Connector::TerminalRenderer.render(input), input.inspect
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

  def test_terminal_line_limit_preserves_the_consumed_prefix_and_allows_recovery
    output = StringIO.new("".b)
    renderer = Connector::TerminalRenderer.new(output, max_line_bytes: 4)
    assert_equal 4, renderer.write("abcd")
    assert_raises(Connector::OutputLimitExceeded) { renderer.write("\r12345") }
    renderer.write("\nnext")
    renderer.finish
    assert_equal "1234\nnext", output.string
  end

  def test_strict_terminal_rendering_validates_utf8_after_fragmented_edits
    output = StringIO.new("".b)
    renderer = Connector::TerminalRenderer.new(output, strict_utf8: true)
    bytes = "名称".b
    renderer.write(bytes.byteslice(0, 2))
    renderer.write(bytes.byteslice(2..))
    renderer.write(" \n")
    renderer.finish
    assert_equal "名称\n".b, output.string
    assert_raises(Encoding::InvalidByteSequenceError) do
      Connector::TerminalRenderer.render("名\bX", strict_utf8: true)
    end
  end

  def test_plain_terminal_rendering_returns_owned_bytes_and_retains_default_validation
    input = "status  ".freeze
    rendered = Connector::TerminalRenderer.render(input, strict_utf8: true)
    assert_equal "status", rendered
    assert_equal Encoding::BINARY, rendered.encoding
    refute rendered.frozen?
    rendered.replace("changed")
    assert_equal "status  ", input
    assert_raises(ArgumentError) { Connector::TerminalRenderer.render("status", strict_utf8: nil) }
    assert_raises(Connector::OutputLimitExceeded) { Connector::TerminalRenderer.render("a" * ((32 * 1024 * 1024) + 1)) }
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
