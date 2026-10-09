# frozen_string_literal: true

require "minitest/autorun"
require "logger"
require "stringio"
require "json"
require "tmpdir"
require "timeout"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class LoggingTest < Minitest::Test
  class RenderedDetailError < Net::Connector::DeviceError
    def initialize(message, **context)
      @detail = message
      super
    end

    def message = "vendor diagnostic: #{@detail}"
  end

  def setup
    @devices = []
    @records = []
    @output = StringIO.new
    @logger = Logger.new(@output)
    @logger.formatter = lambda do |severity, _time, _program, event|
      @records << [severity, event]
      "#{JSON.generate(event.to_h)}\n"
    end
  end

  def teardown
    @devices.each(&:close)
  end

  def build(*responses, **options)
    klass = Class.new(Net::Connector::Base) do
      profile do
        prompts do
          login(/router#\z/)
          command(/router#\z/)
        end
      end
    end
    klass.new(host: "192.0.2.1", username: "operator", transport: ConnectorFake.new(*responses),
              **{ logger: @logger }.merge(options)).tap { |device| @devices << device }
  end

  def records(name)
    @records.map(&:last).map(&:to_h).select { |event| event[:event] == name }
  end

  def test_info_events_correlate_commands_and_include_source_timing_and_response_size
    device = build("router#", "one\nrouter#", "two\nrouter#")
    commands = [Net::Connector::Command.new("show one", source: "commands.cli", line: 3),
                Net::Connector::Command.new("show two", source: "commands.cli", line: 4)]
    assert device.execute_script(commands).success?
    started = records("command_start")
    completed = records("command_complete")
    assert_equal([1, 2], started.map { |event| event[:command_id] })
    assert_equal([3, 4], completed.map { |event| event[:line] })
    assert_equal(["show one", "show two"], completed.map { |event| event[:text] })
    completed.zip(started).each do |finish, start|
      assert_equal start.slice(:host, :session_id, :command_id), finish.slice(:host, :session_id, :command_id)
      assert_equal "commands.cli", finish[:source]
      assert_equal "script", finish[:operation]
      assert_equal "command", finish[:phase]
      assert_equal "response_received", finish[:status]
      assert_equal "one\nrouter#".bytesize, finish[:response_bytes]
      assert_kind_of Integer, finish[:duration_ms]
      assert_operator finish[:duration_ms], :>=, 0
    end
    assert_empty records("device_output")
  end

  def test_shared_logger_and_reconnections_have_independent_session_ids
    first = build("router#", "router#", "router#", "router#")
    second = build("router#", "router#")
    first.execute_command("show first")
    second.execute_command("show second")
    first.close
    first.execute_command("show again")
    starts = records("command_start")
    assert_equal 3, starts.map { |event| event[:session_id] }.uniq.size
    assert_equal([1, 1, 1], starts.map { |event| event[:command_id] })
    assert_equal(records("connect").map { |event| event[:session_id] }, starts.map { |event| event[:session_id] })
  end

  def test_current_logger_level_is_respected_without_changing_its_configuration
    formatter = @logger.formatter
    @logger.progname = "application"
    @logger.level = Logger::INFO
    device = build("router#", "hidden\nrouter#", "visible\nrouter#", "hidden again\nrouter#", log_level: :debug)
    device.execute_command("show first")
    @logger.level = Logger::DEBUG
    device.execute_command("show second")
    @logger.level = Logger::WARN
    device.execute_command("show third")
    device.close
    assert_equal(["visible", "router#"], records("device_output").filter_map { |event| event[:output] })
    assert_equal Logger::WARN, @logger.level
    assert_same formatter, @logger.formatter
    assert_equal "application", @logger.progname
    refute @output.closed?
  end

  def test_failure_events_include_code_phase_duration_and_command_identity
    device = build("router#", :timeout)
    result = device.execute_command("show missing")
    assert_instance_of Net::Connector::CommandTimeout, result.error
    failure = records("command_complete").last
    assert_equal "failed", failure[:status]
    assert_equal "command_timeout", failure[:code]
    assert_equal "command", failure[:phase]
    assert_equal result.error.class.name, failure[:error]
    assert_equal records("command_start").last[:command_id], failure[:command_id]
    assert_kind_of Integer, failure[:duration_ms]
    assert_equal "ERROR", @records.last.first
  end

  def test_login_failure_has_connection_identity_and_error_code
    device = build(:timeout)
    assert_raises(Net::Connector::LoginTimeout) { device.connect }
    failure = records("login_complete").last
    assert_equal "login_timeout", failure[:code]
    assert_equal "login", failure[:phase]
    assert_equal records("connect").last[:session_id], failure[:session_id]
    refute failure.key?(:command_id)
  end

  def test_custom_events_preserve_safe_fields_and_cannot_spoof_device_identity
    device = build("router#", password: "event-secret")
    device.connect
    dangerous = Object.new
    def dangerous.to_s = raise("must not inspect arbitrary log values")
    device.log_event("audit\ncomplete", status: :ok, count: 2, changed: true,
                        token: :"event-secret", nested: { token: "event-secret" }, object: dangerous,
                        missing_number: Float::NAN, infinite_number: Float::INFINITY,
                        host: "forged", session_id: "forged", event: "forged", "bad\nkey": "unsafe")
    event = @records.last.last
    fields = event.to_h
    assert_equal "audit complete", event.name
    assert_equal 2, fields[:count]
    assert fields[:changed]
    assert_equal "ok", fields[:status]
    assert_equal "192.0.2.1", fields[:host]
    assert_equal records("connect").last[:session_id], fields[:session_id]
    assert_equal "[REDACTED]", fields[:token]
    assert_equal "[REDACTED]", fields[:nested]
    assert_equal "[REDACTED]", fields[:object]
    assert_equal "[REDACTED]", fields[:missing_number]
    assert_equal "[REDACTED]", fields[:infinite_number]
    assert_equal "[REDACTED]", JSON.parse(JSON.generate(fields)).fetch("infinite_number")
    refute fields.key?(:"bad\nkey")
    assert event.frozen?
    assert fields.frozen?
    assert fields[:token].frozen?
    refute_includes event.inspect, "event-secret"
    assert_equal 1, event.to_s.lines.size
  end

  def test_custom_events_inside_sensitive_hooks_cannot_leak_unregistered_output
    secret = "private-config-value"
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", logger: @logger,
                                  log_level: :debug, transport: ConnectorFake.new("router#", "router#", "hostname #{secret}\nrouter#"))
    @devices << device
    device.define_singleton_method(:clean_config) do |raw|
      log_event(raw, raw: raw, **{ raw => raw })
      super(raw)
    end
    result = device.running_config
    assert result.success?
    assert_includes result.config, secret
    refute_includes @output.string, secret
    assert_equal "[REDACTED]", records("custom").last[:details]
    device.log_event("ordinary", details: "visible")
    assert_equal "visible", records("ordinary").last[:details]
  end

  def test_sensitive_cleaner_error_metadata_cannot_leak_configuration
    %i[code phase].product(%i[string symbol]).each do |field, type|
      secret = "private-config-value"
      device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", logger: @logger,
                                    transport: ConnectorFake.new("router#", "router#", "hostname #{secret}\nrouter#"))
      @devices << device
      device.define_singleton_method(:clean_config) do |raw|
        value = type == :symbol ? raw.to_sym : raw
        raise Net::Connector::DeviceError.new("configuration rejected", **{ field => value })
      end
      result = device.running_config
      assert result.failure?
      assert_includes result.output, secret
      assert_equal "[REDACTED]", result.error.message
      refute_includes @output.string, secret
      completion = records("operation_complete").last
      assert_equal "failed", completion[:status]
      assert_equal "Net::Connector::DeviceError", completion[:error]
      if field == :code
        assert_nil completion[:code]
      else
        assert_equal "script", completion[:phase]
      end
    end
  end

  def test_transport_error_metadata_is_filtered_at_connection_and_command_boundaries
    %i[connect command].each do |phase|
      secret = "private-transport-value"
      device = build("router#")
      transport = device.instance_variable_get(:@session).transport
      failure = Net::Connector::DeviceError.new("transport rejected", code: secret, phase: secret.to_sym)
      if phase == :connect
        transport.define_singleton_method(:open) { raise failure }
        assert_raises(Net::Connector::DeviceError) { device.connect }
      else
        transport.on_write = ->(*) { raise failure }
        assert device.execute_command("show config", output_sensitive: true).failure?
      end
      refute_includes @output.string, secret
      completion = records(phase == :connect ? "connect_failed" : "command_complete").last
      assert_equal "failed", completion[:status]
      assert_nil completion[:code]
      assert_equal phase.to_s, completion[:phase]
    end
  end

  def test_returned_finalizer_failure_is_private_and_preserves_completed_output
    secret = "private-finalizer-value"
    device = build("router#", "hostname #{secret}\nrouter#")
    command = Net::Connector::Command.new("show config", output_sensitive: true)
    result = device.execute_operation(Net::Connector::Script.new([command]), name: :collect) do |completed|
      failure = Net::Connector::DeviceError.new(completed.output, code: :incomplete_configuration,
                                                phase: :collect, command: completed.output)
      Net::Connector::Result.new(steps: completed.steps, config: completed.output, error: failure)
    end
    assert result.failure?
    assert_equal 1, result.steps.size
    assert_includes result.output, secret
    assert_includes result.config, secret
    assert_equal "[REDACTED]", result.error.message
    assert_equal "[REDACTED]", result.error.command
    refute_includes @output.string, secret
    refute_includes @records.map { |_, event| event.to_s }.join, secret
    completion = records("operation_complete").last
    assert_equal "incomplete_configuration", completion[:code]
    assert_equal "collect", completion[:phase]
    assert_equal "failed", completion[:status]
  end

  def test_finalizer_inherits_effective_command_and_interaction_sensitivity
    %i[explicit prepared prepared_output interaction before_batch failed_probe].each do |kind|
      secret = "private-#{kind}-value"
      replies = ["router#", "#{secret}\nrouter#"]
      replies.insert(1, "Token:") if kind == :interaction
      replies.insert(1, "ready\nrouter#") if kind == :before_batch
      replies.insert(1, ->(*) { raise Net::Connector::DeviceError, secret }) if kind == :failed_probe
      device = build(*replies)
      options = {}
      if kind == :interaction
        options[:interactions] = [Net::Connector::Interaction.new(/Token:\z/, "#{secret}\n", sensitive: true)]
      end
      command = Net::Connector::Command.new("show config", **options, sensitive: kind == :explicit)
      if %i[prepared prepared_output].include?(kind)
        device.define_singleton_method(:prepare_command) do |original, _|
          Net::Connector::Command.new(original.text, sensitive: kind == :prepared, output_sensitive: kind == :prepared_output)
        end
      end
      if %i[before_batch failed_probe].include?(kind)
        device.define_singleton_method(:before_batch) do |execution|
          execution.execute_command(Net::Connector::Command.new("set token #{secret}", sensitive: true))
        rescue Net::Connector::DeviceError
          nil
        end
      end
      result = device.execute_operation(Net::Connector::Script.new([command]), name: :collect) do |completed|
        failure = Net::Connector::DeviceError.new(secret, command: secret)
        Net::Connector::Result.new(steps: completed.steps, error: failure)
      end
      assert result.failure?
      assert_includes result.output, secret
      assert_equal "[REDACTED]", result.error.message
      assert_equal "[REDACTED]", result.error.command
      refute_includes @output.string, secret
    end
  end

  def test_returned_completion_errors_keep_their_receipts_after_normalization
    receipt = Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: "backup.cfg", completed_at: Time.now.utc)
    transfer_error = Net::Connector::TftpCompletionError.new(receipt: receipt)
    backup = Net::Connector::Backup.new(path: "/fixture/backup.cfg", bytes: 6, sha256: "a" * 64, collected_at: Time.now.utc)
    write_receipt = Net::Connector::Storage::PrivateFile::Receipt.new(path: backup.path, state: :committed, phase: :directory_sync)
    write_error = Net::Connector::Storage::PrivateFile::PersistenceError.new(receipt: write_receipt, underlying_type: "Errno::EIO")
    backup_error = Net::Connector::BackupPersistenceError.new(backup: backup, write_error: write_error)
    [transfer_error, backup_error].each do |failure|
      secret = "private-original-cause"
      begin
        raise failure, cause: RuntimeError.new(secret)
      rescue Net::Connector::Error => original
        original.set_backtrace(["#{secret}:42"])
      end
      device = build("router#", "configuration\nrouter#")
      script = Net::Connector::Script.new([Net::Connector::Command.new("show config", output_sensitive: true)])
      result = device.execute_operation(script, name: :collect) do |completed|
        Net::Connector::Result.new(steps: completed.steps, config: completed.output, error: failure)
      end
      assert_instance_of failure.class, result.error
      assert_same failure.receipt, result.error.receipt
      assert_equal failure.code, result.error.code
      assert_equal 1, result.steps.size
      assert_includes result.config, "configuration"
      assert_equal "[REDACTED]", result.error.message
      assert_nil result.error.cause
      assert_nil result.error.backtrace
      assert_nil result.error.backtrace_locations
      refute_includes result.error.full_message, secret
      assert_equal secret, failure.cause.message
      refute_same failure, result.error
    end
  end

  def test_custom_error_diagnostic_fields_are_rebuilt_from_sanitized_text
    secret = "private-custom-error-detail"
    device = build("router#", "#{secret}\nrouter#")
    command = Net::Connector::Command.new("show config", output_sensitive: true)
    result = device.execute_operation(Net::Connector::Script.new([command]), name: :collect) do |completed|
      Net::Connector::Result.new(steps: completed.steps, error: RenderedDetailError.new(completed.output))
    end
    assert_instance_of RenderedDetailError, result.error
    refute_includes result.error.message, secret
    refute_includes @output.string, secret
    assert_includes result.output, secret
  end

  def test_lease_context_covers_internal_scripts_and_is_released_afterward
    device = build("router#", "router#", "router#")
    device.with_operation(:audit) do
      device.execute_command("show audit")
      device.log_event("audit_complete", count: 1, operation: "forged", command_id: 99)
    end
    device.execute_command("show ordinary")
    assert_equal(%w[audit script], records("command_start").map { |event| event[:operation] })
    assert_equal "audit", records("audit_complete").last[:operation]
    refute records("audit_complete").last.key?(:command_id)
  end

  def test_operation_failure_after_response_does_not_report_business_success
    device = build("router#", "reply\nrouter#")
    result = device.execute_command("show status") { raise "callback failed" }
    assert result.failure?
    assert_equal "response_received", records("command_complete").last[:status]
    completion = records("operation_complete").last
    assert_equal "failed", completion[:status]
    assert_equal result.error.code.to_s, completion[:code]
    assert_equal 1, completion[:steps]
    assert_equal "script", completion[:operation]
    refute completion.key?(:command_id)
  end

  def test_file_transcript_flushes_partial_lines_before_changing_command_context
    Dir.mktmpdir do |directory|
      file = File.join(directory, "session.log")
      device = build("router#", "first line\nrouter#", "second line\nrouter#",
                     logger: nil, log_file: file, log_level: :debug)
      device.execute_script(["show one", "show two"])
      device.close
      lines = File.read(file).lines
      output = lines.grep(/event=device_output.*phase=command.*output=/)
      assert_equal(["1", "1", "2", "2"], output.map { |line| line[/command_id=(\d+)/, 1] })
      assert_equal(["first line", "router#", "second line", "router#"], output.map { |line| line[/output="([^"]+)"/, 1] })
      assert(lines.all? { |line| line.include?("session_id=") && line.include?("[host=192.0.2.1]") })
      assert_operator(lines.index(output[1]), :<, lines.index { |line| line.include?("event=command_complete") })
    end
  end

  def test_logger_duck_type_does_not_need_unused_formatter_or_close_methods
    messages = []
    logger = Object.new
    logger.define_singleton_method(:level) { Logger::INFO }
    %i[debug info warn error].each { |level| logger.define_singleton_method(level) { |message| messages << message } }
    device = build("router#", logger: logger)
    device.connect
    device.close
    assert_equal %w[connect login_complete], messages.map(&:name)
  end

  def test_event_observer_is_independent_of_logger_threshold_and_keeps_redaction
    events = []
    @logger.level = Logger::ERROR
    device = build("router#", "private-output\nrouter#", password: "private-password",
                   on_event: ->(event) { events << event })
    command = Net::Connector::Command.new("secret private-password", sensitive: true)
    assert device.execute_script([command]).success?
    assert_empty @records
    assert events.all?(&:frozen?)
    assert_includes events.map(&:name), "command_start"
    refute_includes events.map(&:to_s).join, "private-password"
    refute_includes events.map(&:to_s).join, "private-output"
    assert_equal Logger::ERROR, @logger.level
  end

  def test_observer_failure_is_an_explicit_log_failure_without_leaking_callback_error
    device = build("router#", logger: nil, password: "private-password", on_event: ->(_) { raise "private-password" })
    error = assert_raises(Net::Connector::LogError) { device.connect }
    refute_includes error.message, "private-password"
    refute device.connected?
    assert_raises(ArgumentError) { Net::Connector::Configuration.new(on_event: Object.new) }
  end

  def test_log_failure_after_a_response_keeps_the_completed_step_without_replaying_commands
    %w[command_complete device_output].each do |name|
      observer = lambda do |event|
        raise IOError, "event sink unavailable" if event.name == name && event.fields[:phase] == "command" &&
                                                 (event.fields[:status] == "response_received" || event.fields.key?(:output))
      end
      device = build("router#", "changed successfully\nrouter#", "unused\nrouter#",
                     log_level: :debug, on_event: observer)
      result = device.execute_script(["change", "next command"])
      assert_instance_of Net::Connector::LogError, result.error
      assert_equal ["change"], (result.steps.map { |step| step.command.text })
      assert_equal "changed successfully\nrouter#", result.output
      assert_equal ["change\n"], device.instance_variable_get(:@session).transport.writes
      refute device.connected?
    end
  end

  def test_operation_completion_failure_retains_finalized_configuration_and_is_not_reported_twice
    attempts = 0
    observer = lambda do |event|
      next unless event.name == "operation_complete"

      attempts += 1
      raise IOError, "event sink unavailable"
    end
    device = build("router#", "hostname sample\nrouter#", on_event: observer)
    script = Net::Connector::Script.new([Net::Connector::Command.new("show config", output_sensitive: true)])
    result = device.execute_operation(script, name: :collect) do |completed|
      Net::Connector::Result.new(steps: completed.steps, config: "hostname sample\n")
    end

    assert_equal "hostname sample\n", result.config
    assert_instance_of Net::Connector::LogError, result.error
    assert_equal 1, attempts
    assert_equal ["show config\n"], device.instance_variable_get(:@session).transport.writes
    assert_equal 1, result.steps.size
    refute device.connected?
  end

  def test_failure_reporting_preserves_returned_and_raised_business_errors
    %i[returned raised].each do |kind|
      attempts = 0
      observer = lambda do |event|
        next unless event.name == "operation_complete"

        attempts += 1
        raise IOError, "private observer failure"
      end
      device = build("router#", "hostname sample\nrouter#", on_event: observer)
      result = device.execute_operation(Net::Connector::Script.new(["show config"]), name: :collect) do |completed|
        failure = Net::Connector::DeviceError.new("configuration rejected", code: :incomplete_configuration)
        raise failure if kind == :raised

        Net::Connector::Result.new(steps: completed.steps, config: "hostname sample\n", error: failure)
      end

      assert_instance_of Net::Connector::DeviceError, result.error
      assert_equal :incomplete_configuration, result.error.code
      assert_equal "hostname sample\n", result.config if kind == :returned
      assert_equal 1, attempts
      assert_equal ["show config\n"], device.instance_variable_get(:@session).transport.writes
      assert_equal 1, result.steps.size
      refute_includes result.error.full_message, "private observer failure"
    end
  end

  def test_failure_logging_does_not_replace_command_or_login_failure
    %i[command login].each do |phase|
      observer = lambda do |event|
        raise IOError, "event sink unavailable" if event.fields[:status] == "failed"
      end
      device = build("router#", ->(*) { raise Net::Connector::CommandTimeout, "response timed out" }, on_event: observer)
      transport = device.instance_variable_get(:@session).transport
      if phase == :login
        transport.define_singleton_method(:open) { raise Net::Connector::ConnectionError, "connection failed" }
        assert_raises(Net::Connector::ConnectionError) { device.connect }
        assert_empty transport.writes
      else
        result = device.execute_command("change")
        assert_instance_of Net::Connector::CommandTimeout, result.error
        assert_equal ["change\n"], transport.writes
      end
      refute device.connected?
    end
  end

  def test_fifo_log_path_fails_before_opening_transport_even_without_a_reader
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      File.mkfifo(path, 0o640)
      device = build("router#", logger: nil, log_file: path, login_timeout: 0.01)
      assert_raises(Net::Connector::LogError) { Timeout.timeout(1) { device.connect } }
      assert_equal 0, device.instance_variable_get(:@session).transport.opens
      assert_equal 0o640, File.stat(path).mode & 0o777
      refute device.connected?
    end
  end

  def test_transcript_reattachment_failure_keeps_a_completed_sensitive_response
    Dir.mktmpdir do |directory|
      device = build("router#", "private configuration\nrouter#", logger: nil, log_level: :debug,
                     log_file: File.join(directory, "session.log"))
      transport = device.instance_variable_get(:@session).transport
      attach = transport.method(:log_output=)
      failed = false
      transport.define_singleton_method(:log_output=) do |output|
        if output && !writes.empty? && !failed
          failed = true
          raise IOError, "transcript reattachment failed"
        end
        attach.call(output)
      end

      result = device.execute_command("show config", output_sensitive: true)
      assert result.failure?
      assert_equal ["show config"], (result.steps.map { |step| step.command.text })
      assert_equal "private configuration\nrouter#", result.output
      assert_equal ["show config\n"], transport.writes
      refute_includes File.read(File.join(directory, "session.log")), "private configuration"
      refute device.connected?
    end
  end

  def test_fifo_log_path_with_a_reader_is_rejected_without_writing_or_chmod
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      File.mkfifo(path, 0o640)
      File.open(path, File::RDONLY | File::NONBLOCK) do |reader|
        device = build("router#", logger: nil, log_file: path)
        assert_raises(Net::Connector::LogError) { device.connect }
        assert_equal 0, device.instance_variable_get(:@session).transport.opens
        assert_equal 0o640, File.stat(path).mode & 0o777
        assert_equal "", reader.read
      end
    end
  end
end
