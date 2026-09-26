# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class RedactionContractTest < Minitest::Test
  MARKER = "[REDACTED]"
  SECRET = "callback-secret-8492"

  def test_sensitive_command_remains_redacted_in_callback_errors
    device, = build("fw#")
    result = device.execute("set password #{SECRET}", sensitive: true) { raise "callback rejected #{SECRET}" }

    assert_private_failure(result)
    assert_equal MARKER, result.error.command
    assert_equal 1, result.steps.size
  ensure
    device&.close
  end

  def test_sensitive_command_is_registered_before_preparation
    device, transport = build
    device.define_singleton_method(:prepare_command) { |command, _| raise "invalid #{command.text.split.last}" }
    result = device.execute("set password #{SECRET}", sensitive: true)

    assert_private_failure(result)
    assert_equal MARKER, result.error.command
    assert_empty transport.writes
  ensure
    device&.close
  end

  def test_prepared_sensitive_command_is_redacted_in_vendor_hook_errors
    device, = build("fw#")
    device.define_singleton_method(:prepare_command) do |_, _|
      Net::Connector::Command.new("set password #{SECRET}", sensitive: true)
    end
    device.define_singleton_method(:after_command) { |_, _, _| raise "invalid #{SECRET}" }
    result = device.execute("replace password")

    assert_private_failure(result)
    assert_equal MARKER, result.error.command
    assert_equal 1, result.steps.size
  ensure
    device&.close
  end

  def test_sensitive_interaction_remains_redacted_through_user_callback
    device, = build("Token:", "fw#")
    result = device.execute("renew token", interactions: [token_interaction]) { raise "invalid #{SECRET}" }

    assert_private_failure(result)
    assert_equal "renew token", result.error.command
  ensure
    device&.close
  end

  def test_after_command_query_keeps_dynamic_secret_until_outer_callback_finishes
    device, = build("fw#", "Token:", "fw#")
    interaction = token_interaction
    device.define_singleton_method(:after_command) do |_, _, execution|
      execution.query(Net::Connector::Command.new("renew token", interactions: [interaction]))
    end
    result = device.execute("refresh state") { raise "invalid #{SECRET}" }

    assert_private_failure(result)
  ensure
    device&.close
  end

  def test_failing_sensitive_interaction_does_not_expose_a_partial_token
    device, = build("Token:")
    interaction = Net::Connector::Interaction.new(/Token:\z/, ->(_) { raise "rejected #{SECRET[0, 12]}" }, sensitive: true)
    result = device.execute("renew token", interactions: [interaction])

    assert_private_failure(result, SECRET[0, 12])
  ensure
    device&.close
  end

  def test_failing_login_challenge_redacts_partial_secrets_before_logging_or_wrapping
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      partial = SECRET[0, 12]
      interaction = Net::Connector::Interaction.new(/Token:\z/, lambda { |_|
        failure = RuntimeError.new("provider rejected #{partial}")
        failure.set_backtrace(["#{partial}:42"])
        raise failure
      })
      transport = ConnectorFake.new("Token:")
      device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit",
                                    transport: transport, challenges: [interaction], log_file: path)
      failure = assert_raises(Net::Connector::InternalError) { device.connect }
      device.close

      fields = [failure.message, failure.command, failure.output, failure.underlying.message,
                failure.underlying.backtrace, File.read(path)]
      refute_includes JSON.generate(fields), partial
      assert_equal "RuntimeError", failure.underlying.type
      assert_nil failure.cause
      assert transport.closed?
      assert_empty transport.writes
      assert_includes File.read(path), MARKER
    ensure
      device&.close
    end
  end

  def test_successful_login_challenge_keeps_token_redaction_without_hiding_ordinary_errors
    interaction = Net::Connector::Interaction.new(/Token:\z/, ->(_) { "#{SECRET}\n" })
    transport = ConnectorFake.new("Token:", "fw#", "fw#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit",
                                  transport: transport, challenges: [interaction])
    device.connect
    redactor = device.instance_variable_get(:@session).redactor
    assert_equal MARKER, redactor.call(SECRET)
    refute redactor.sensitive?
    result = device.execute("show status") { raise "ordinary callback failed" }
    assert_equal "ordinary callback failed", result.error.underlying.message
    assert_includes transport.writes, "#{SECRET}\n"
  ensure
    device&.close
  end

  def test_sensitive_domain_error_is_resanitized_including_its_underlying_snapshot
    device, = build("fw#")
    result = device.execute("set password #{SECRET}", sensitive: true) do
      original = RuntimeError.new("rejected #{SECRET[0, 12]}")
      original.set_backtrace(["#{SECRET}:42"])
      unsafe = Net::Connector::UnderlyingError.new(original, Net::Connector::Redactor.new)
      raise Net::Connector::ScriptError.new("rejected #{SECRET}", phase: :script, command: SECRET,
                                            output: SECRET, underlying: unsafe)
    end

    assert_private_failure(result, SECRET[0, 12])
    assert_equal MARKER, result.error.command
  ensure
    device&.close
  end

  def test_sensitive_interaction_does_not_trust_a_callback_supplied_error_command
    device, = build("Token:", "fw#")
    result = device.execute("renew token", interactions: [token_interaction]) do
      raise Net::Connector::ScriptError.new("rejected token", command: SECRET[0, 12])
    end
    assert result.failure?
    refute_includes result.error.command, SECRET[0, 12]
    assert_equal :script_error, result.error.code
  ensure
    device&.close
  end

  def test_ordinary_callback_error_retains_diagnostic_message_and_backtrace
    device, = build("fw#")
    result = device.execute("show status") { raise "ordinary callback failed" }

    assert_instance_of Net::Connector::InternalError, result.error
    assert_equal "show status", result.error.command
    assert_equal "RuntimeError", result.error.underlying.type
    assert_equal "ordinary callback failed", result.error.underlying.message
    refute_empty result.error.underlying.backtrace
  ensure
    device&.close
  end

  def test_completed_and_skipped_commands_release_the_sensitive_scope
    device, = build("fw#", "fw#")
    first = device.execute("set password #{SECRET}", sensitive: true)
    assert first.success?, first.error&.message
    session = device.instance_variable_get(:@session)
    assert_equal SECRET, session.redactor.call(SECRET)
    result = device.execute("show status") { raise "ordinary callback failed" }
    assert_equal "ordinary callback failed", result.error.underlying.message
    device.close

    device, = build
    device.define_singleton_method(:prepare_command) { |_, _| nil }
    assert device.execute("set password #{SECRET}", sensitive: true).success?
    assert_equal "set password #{SECRET}", device.instance_variable_get(:@session).redactor.call("set password #{SECRET}")
  ensure
    device&.close
  end

  def test_failed_command_releases_dynamic_secret_scope
    device, = build("Token:", "fw#")
    result = device.execute("renew token", interactions: [token_interaction]) { raise "rejected #{SECRET}" }
    assert result.failure?
    assert_equal SECRET, device.instance_variable_get(:@session).redactor.call(SECRET)
  ensure
    device&.close
  end

  def test_nested_redactor_scopes_restore_the_outer_dictionary_even_on_failure
    redactor = Net::Connector::Redactor.new("permanent")
    redactor.scope do
      redactor.remember("outer")
      assert_raises(RuntimeError) do
        redactor.scope do
          redactor.remember("inner")
          assert_equal "#{MARKER} #{MARKER} #{MARKER}", redactor.call("permanent outer inner")
          raise "failed inner scope"
        end
      end
      assert_equal "#{MARKER} #{MARKER} inner", redactor.call("permanent outer inner")
    end
    assert_equal "#{MARKER} outer inner", redactor.call("permanent outer inner")
  end

  def test_real_secret_containing_marker_is_matched_before_marker_preservation
    secrets = ["alpha[REDACTED]omega", "[REDACTED]suffix", "prefix[REDACTED]", "REDACTED", "[", "alpha"]
    redactor = Net::Connector::Redactor.new(*secrets)
    input = "alpha[REDACTED]omega | [REDACTED]suffix | prefix[REDACTED] | [REDACTED] | REDACTED | alpha"
    expected = ([MARKER] * 6).join(" | ")

    assert_equal expected, redactor.call(input)
    assert_equal expected, redactor.call(expected)
  end

  def test_streaming_redaction_matches_direct_redaction_at_every_split_and_byte
    secrets = ["alpha[REDACTED]omega", "[REDACTED]suffix", "prefix[REDACTED]", "alpha", "REDACTED", "["]
    input = "start alpha[REDACTED]omega [REDACTED]suffix prefix[REDACTED] [REDACTED] end"
    expected = "start #{MARKER} #{MARKER} #{MARKER} #{MARKER} end"
    (0..input.bytesize).each do |split|
      redactor = Net::Connector::Redactor.new(*secrets)
      assert_equal expected, redact_chunks(redactor, [input.byteslice(0, split), input.byteslice(split..)]), "split #{split}"
    end
    assert_equal expected, redact_chunks(Net::Connector::Redactor.new(*secrets), input.bytes.map { |byte| byte.chr })
  end

  def test_log_writers_do_not_expose_secrets_containing_a_marker
    %i[raw text].each do |format|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "session.log")
        secret = "prefix[REDACTED]suffix"
        transport = ConnectorFake.new("fw#", "prefix[REDA", "CTED]suffix\nfw#")
        device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit", password: secret,
                                      transport: transport, log_file: path, log_format: format, log_level: :debug)
        assert device.execute("show status").success?
        device.close
        contents = File.read(path)
        assert_includes contents, "[REDACTED]"
        refute_includes contents, secret
      ensure
        device&.close
      end
    end
  end

  def test_overlapping_secrets_and_marker_suffixes_are_fully_redacted
    secrets = ["abc", "cde", "ACTED]xyz"]
    input = "abcde [REDACTED]xyz"
    expected = "#{MARKER} #{MARKER}"
    assert_equal expected, Net::Connector::Redactor.new(*secrets).call(input)
    (0..input.bytesize).each do |split|
      chunks = [input.byteslice(0, split), input.byteslice(split..)]
      assert_equal expected, redact_chunks(Net::Connector::Redactor.new(*secrets), chunks), "split #{split}"
    end
    assert_equal expected, redact_chunks(Net::Connector::Redactor.new(*secrets), input.bytes.map(&:chr))
  end

  private

  def build(*events)
    transport = ConnectorFake.new("fw#", *events)
    [Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport), transport]
  end

  def token_interaction
    Net::Connector::Interaction.new(/Token:\z/, ->(_) { "#{SECRET}\n" }, sensitive: true)
  end

  def assert_private_failure(result, secret = SECRET)
    assert result.failure?
    error = result.error
    fields = [error.message, error.command, error.output, error.underlying&.message, error.underlying&.backtrace]
    refute_includes JSON.generate(fields), secret
    assert_equal "RuntimeError", error.underlying.type if error.underlying
    assert_nil error.cause
  end

  def redact_chunks(redactor, chunks)
    pending = "".b
    output = "".b
    chunks.each do |chunk|
      safe, pending = redactor.stream_chunk(pending + chunk)
      output << safe
    end
    safe, = redactor.stream_chunk(pending, final: true)
    output + safe
  end
end
