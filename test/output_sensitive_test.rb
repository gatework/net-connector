# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "logger"
require "securerandom"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class OutputSensitiveTest < Minitest::Test
  Connector = Net::Connector
  LOG_MODES = %i[info debug raw external].freeze

  def setup
    # 配置里的假秘密与登录凭据分别生成，不预先登记到会话词表。
    @secret = "fixture-#{SecureRandom.hex(24)}"
    @body = "service opaque #{@secret}\nrouter#"
  end

  def teardown = @device&.close

  def test_command_output_sensitivity_is_independent_and_copied
    command = Connector::Command.new("show config", timeout: 3, prompt: /router#\z/,
                                     output_sensitive: true, source: "fixture", line: 7)
    refute command.sensitive?
    assert command.output_sensitive?
    copy = command.with_text("show running-config")
    assert copy.output_sensitive?
    refute copy.sensitive?
    assert_equal [3, /router#\z/, "fixture", 7], [copy.timeout, copy.prompt, copy.source, copy.line]
    assert copy.frozen?
    ordinary = Connector::Command.new("show status")
    refute ordinary.output_sensitive?
    refute Connector::Command.new("set value", sensitive: true).output_sensitive?
    assert ordinary.with_output_sensitive.output_sensitive?
    refute ordinary.output_sensitive?
    [nil, 0, "true", Object.new].each do |invalid|
      assert_raises(ArgumentError) { Connector::Command.new("show", output_sensitive: invalid) }
    end
  end

  def test_configuration_is_private_in_every_log_mode_and_preserved_in_results_and_backups
    LOG_MODES.each do |mode|
      with_log(mode) do |options, contents, directory|
        build("router#", @body, "router#", @body, "ordinary output\nrouter#", **options)
        result = @device.running_config
        assert result.success?, result.error.inspect
        assert_equal @body, result.value!
        assert_equal @body, result.steps.last.output
        assert(result.steps.all? { |step| step.command.output_sensitive? })
        backup = @device.backup(path: File.join(directory, "backup.txt"))
        assert_equal @body, File.binread(backup.path)
        assert_equal Digest::SHA256.hexdigest(@body), backup.sha256
        assert_equal @body.bytesize, backup.bytes

        ordinary = @device.execute_command("show status") { raise "ordinary callback failed" }
        assert_equal "ordinary callback failed", ordinary.error.underlying.message
        refute_empty ordinary.error.underlying.backtrace
        @device.close
        refute_includes contents.call, @secret, mode.to_s
        assert_includes contents.call, "ordinary output" unless mode == :info
        assert_includes contents.call, "show running-config" unless mode == :raw
        redactor = @device.instance_variable_get(:@session).redactor
        assert_equal @secret, redactor.call(@secret)
        refute redactor.sensitive?
      end
    end
  end

  def test_control_sequence_fragments_never_enter_diagnostic_writers
    LOG_MODES.each do |mode|
      with_log(mode) do |options, contents, _|
        parts = ["service opaque ", @secret[0, 12], "\e[31m", @secret[12..], "\e[0m\r\nrouter#"]
        build("router#", *parts, **options)
        result = @device.running_config
        assert result.success?, result.error.inspect
        assert_includes result.value!, @secret
        @device.close
        [@secret, @secret[0, 12], @secret[12..]].each { |part| refute_includes contents.call, part }
      end
    end
  end

  def test_timeout_preserves_completed_steps_without_configuration_in_errors_or_logs
    LOG_MODES.each do |mode|
      with_log(mode) do |options, contents, _|
        build("router#", "service opaque #{@secret}", :timeout, **options)
        result = @device.running_config
        assert_private_failure(result, contents.call)
        assert_instance_of Connector::CommandTimeout, result.error
        assert_equal "show running-config", result.error.command
        assert_equal ["terminal length 0"], (result.steps.map { |step| step.command.text })
        assert @transport.closed?
      end
    end
  end

  def test_device_error_and_output_limit_do_not_expose_configuration
    [[:device_error, "% Invalid input #{@secret}\nrouter#", {}],
     [:output_limit_exceeded, @body * 8, { max_output_bytes: 128 }],
     [:script_output_limit_exceeded, @body * 8, { max_script_output_bytes: 128 }]].each do |code, output, limits|
      with_log(:debug) do |options, contents, _|
        build("router#", output, **options, **limits)
        result = @device.running_config
        assert_private_failure(result, contents.call)
        assert_equal code, result.error.code
        assert_equal "show running-config", result.error.command
        assert @transport.closed?
      end
    end
  end

  def test_cleaner_and_result_selection_errors_are_private_after_all_commands_complete
    %i[clean_config config_result_step].each do |hook|
      LOG_MODES.each do |mode|
        with_log(mode) do |options, contents, _|
          build("router#", @body, **options)
          secret = @secret
          @device.define_singleton_method(hook) do |_|
            failure = RuntimeError.new("rejected #{secret}")
            failure.set_backtrace(["#{secret}:42:in 'clean'"])
            raise failure
          end
          result = @device.running_config
          assert_private_failure(result, contents.call)
          assert_equal "RuntimeError", result.error.underlying.type
          assert_equal :script, result.error.phase
          assert_equal 2, result.steps.size
          assert_includes result.output, @secret
          assert @transport.closed?
        end
      end
    end
  end

  def test_domain_error_from_cleaner_is_resanitized_including_underlying_and_backtrace
    build("router#", @body)
    secret = @secret
    @device.define_singleton_method(:clean_config) do |_|
      original = RuntimeError.new(secret)
      original.set_backtrace(["#{secret}:42"])
      underlying = Connector::UnderlyingError.new(original, Connector::Redactor.new)
      failure = Connector::DeviceError.new(secret, phase: :collect, code: :incomplete_configuration,
                                          command: secret, output: secret, underlying: underlying)
      failure.set_backtrace(["#{secret}:42"])
      raise failure
    end
    result = @device.running_config
    assert_private_failure(result)
    assert_equal :collect, result.error.phase
    assert_equal :incomplete_configuration, result.error.code
    assert_equal 2, result.steps.size
  end

  def test_preparation_and_followup_queries_inherit_collection_context
    %i[before_batch prepare_command after_command].each do |hook|
      with_log(:raw) do |options, contents, _|
        events = hook == :after_command ? ["router#", @body] : [@body]
        build(*events, **options)
        @device.define_singleton_method(hook) do |*args|
          execution = args.last
          response = execution.execute_command("show additional config")
          raise "followup failed #{response.output}"
        end
        result = @device.running_config
        assert_private_failure(result, contents.call)
        assert_equal hook == :after_command ? 1 : 0, result.steps.size
        assert_includes @transport.writes, "show additional config\n"
      end
    end
  end

  def test_replacement_command_cannot_disable_collection_privacy
    with_log(:external) do |options, contents, _|
      build(@body, @body, **options)
      @device.define_singleton_method(:prepare_command) do |command, _|
        Connector::Command.new(command.text)
      end
      result = @device.running_config
      assert result.success?, result.error.inspect
      assert_equal @body, result.value!
      @device.close
      refute_includes contents.call, @secret
    end
  end

  def test_custom_strategy_response_check_is_private_and_keeps_completed_step
    strategy = Class.new(Connector::RunningConfig::Strategy) do
      def validate_response!(_command, response, _execution)
        raise "rejected #{response.output}"
      end
    end
    klass = Class.new(Connector.vendor_class(:cisco_ios))
    klass.profile { running_config_strategy strategy }
    @transport = ConnectorFake.new("router#", @body)
    @device = klass.new(host: "192.0.2.1", username: "audit", transport: @transport)
    result = @device.running_config
    assert_private_failure(result)
    assert_equal 1, result.steps.size
    assert_includes result.output, @secret
  end

  def test_all_builtin_vendors_mark_the_entire_collection_including_candidate_queries
    %i[h3c h3c_wireless huawei cisco_ios cisco_nxos radware hillstone palo_alto].each do |vendor|
      with_log(:debug) do |options, contents, _|
        klass = Connector.vendor_class(vendor)
        prompt = case vendor
                 when :h3c, :h3c_wireless, :huawei then "<router>"
                 when :radware then ">> Configuration#"
                 when :palo_alto then "audit@router>"
                 else "router#"
                 end
        events = [prompt]
        events << "privilege level is 3\n#{prompt}" if vendor == :huawei
        klass.profile.config_commands.each do |command|
          prompt = prompt.sub(/>\z/, "#") if command == "configure"
          prompt = prompt.sub(/#\z/, ">") if command == "exit"
          body = command == "show config diff" ? "" : "set system comment #{@secret}\n"
          events << "#{body}#{prompt}"
        end
        @transport = ConnectorFake.new(*events)
        @device = klass.new(host: "192.0.2.1", username: "audit", transport: @transport, **options)
        result = @device.running_config
        assert result.success?, "#{vendor}: #{result.error.inspect}"
        assert result.steps.all? { |step| step.command.output_sensitive? }, vendor.to_s
        assert_includes result.config, @secret
        @device.close
        refute_includes contents.call, @secret
      end
    end
  end

  def test_panos_rejects_candidate_diff_without_recording_its_contents
    with_log(:external) do |options, contents, _|
      @transport = ConnectorFake.new("audit@router>", "audit@router>", "audit@router>",
                                    "show config diff\n+ #{@secret}\naudit@router>")
      @device = Connector.build(:palo_alto, host: "192.0.2.1", username: "audit", transport: @transport, **options)
      result = @device.running_config
      assert_private_failure(result, contents.call)
      assert_equal :uncommitted_configuration, result.error.code
      assert_equal 3, result.steps.size
      assert_includes result.output, @secret
      assert_equal ["set cli pager off\n", "set cli config-output-format set\n", "show config diff\n"], @transport.writes
    end
  end

  def test_explicit_output_sensitive_command_keeps_safe_text_and_protects_callback
    with_log(:debug) do |options, contents, _|
      build(@body, **options)
      secret = @secret
      result = @device.execute_command("show config", output_sensitive: true) { raise "callback #{secret}" }
      assert_private_failure(result, contents.call)
      assert_equal "show config", result.error.command
      assert_equal @body, result.output
      assert_equal 1, result.steps.size
    end
  end

  def test_prepared_output_sensitive_command_protects_vendor_callback
    with_log(:external) do |options, contents, _|
      build(@body, **options)
      @device.define_singleton_method(:prepare_command) do |command, _|
        Connector::Command.new(command.text, output_sensitive: true)
      end
      @device.define_singleton_method(:after_command) { |_, response, _| raise response.output }
      result = @device.execute_command("show config")
      assert_private_failure(result, contents.call)
      assert_equal 1, result.steps.size
    end
  end

  def test_command_level_privacy_expires_before_the_next_ordinary_script_step
    with_log(:external) do |options, contents, _|
      build(@body, "ordinary response\nrouter#", **options)
      command = Connector::Command.new("show config", output_sensitive: true)
      result = @device.execute_script(Connector::Script.new([command, "show status"])) do |step|
        raise "ordinary callback failed" if step.command.text == "show status"
      end
      assert_equal "ordinary callback failed", result.error.underlying.message
      refute_includes contents.call, @secret
      assert_includes contents.call, "ordinary response"
      assert_equal 2, result.steps.size
    end
  end

  def test_unmarked_commands_keep_existing_diagnostics
    with_log(:external) do |options, contents, _|
      build(@body, **options)
      result = @device.execute_command("show config")
      assert result.success?, result.error.inspect
      assert_equal @body, result.output
      assert_includes contents.call, @secret
    end
  end

  def test_copy_for_collection_preserves_sensitive_text_interactions_and_timeouts
    interaction = Connector::Interaction.new(/Continue:\z/, "\n")
    command = Connector::Command.new("show #{@secret}", sensitive: true, interactions: [interaction],
                                     timeout: 4, prompt: /router#\z/, source: "fixture", line: 8)
    copy = command.with_output_sensitive
    assert copy.sensitive?
    assert copy.output_sensitive?
    assert_equal command.text, copy.text
    assert_equal [4, [interaction], /router#\z/, "fixture", 8],
                 [copy.timeout, copy.interactions, copy.prompt, copy.source, copy.line]
    assert copy.with_text("changed").sensitive?
    assert copy.with_text("changed").output_sensitive?
  end

  def test_output_sensitive_preparation_failure_is_private_before_io
    build
    secret = @secret
    @device.define_singleton_method(:prepare_command) { |_, _| raise "rejected #{secret}" }
    result = @device.execute_command("show config", output_sensitive: true)
    assert_private_failure(result)
    assert_equal "show config", result.error.command
    assert_empty @transport.writes
  end

  def test_logger_failure_during_collection_is_private_and_does_not_replay
    stream = StringIO.new
    logger = Logger.new(stream)
    secret = @secret
    bytes = @body.bytesize
    logger.define_singleton_method(:info) do |message|
      if message.to_h[:event] == "command_complete" && message.to_h[:response_bytes] == bytes
        failure = IOError.new("sink failed #{secret}")
        failure.set_backtrace(["#{secret}:42"])
        raise failure
      end
      super(message)
    end
    build("router#", @body, logger: logger, log_level: :debug)
    result = @device.running_config
    assert_private_failure(result, stream.string)
    assert_equal :logging, result.error.phase
    assert_equal "IOError", result.error.underlying.type
    assert_equal ["terminal length 0\n", "show running-config\n"], @transport.writes
    assert_equal 2, result.steps.size
    assert_equal @body, result.steps.last.output
    assert @transport.closed?
  end

  def test_failed_collection_scope_is_released_before_a_new_connection
    build("router#", @body, "router#", "ordinary output\nrouter#")
    secret = @secret
    @device.define_singleton_method(:clean_config) { |_| raise secret }
    result = @device.running_config
    assert_private_failure(result)
    ordinary = @device.execute_command("show status") { raise "ordinary callback failed" }
    assert_equal "ordinary callback failed", ordinary.error.underlying.message
    assert_equal 2, @transport.opens
    assert_equal ["terminal length 0\n", "show running-config\n", "show status\n"], @transport.writes
  end

  def test_output_scope_is_restored_on_nonlocal_exit_and_retains_existing_sensitive_scope
    build("router#", @body, "router#", "ordinary output\nrouter#")
    @device.define_singleton_method(:clean_config) { |_| throw :stop_collection, :stopped }
    assert_equal :stopped, catch(:stop_collection) { @device.running_config }
    assert @transport.closed?
    session = @device.instance_variable_get(:@session)
    refute session.redactor.sensitive?
    refute session.redactor.output_sensitive?
    ordinary = @device.execute_command("show status") { raise "ordinary callback failed" }
    assert_equal "ordinary callback failed", ordinary.error.underlying.message

    session.redactor.with_scope do
      session.redactor.sensitive!
      session.with_sensitive_output(true) { assert session.redactor.output_sensitive? }
      assert session.redactor.sensitive?
      refute session.redactor.output_sensitive?
    end
    refute session.redactor.sensitive?
  end

  private

  def build(*events, **options)
    @transport = ConnectorFake.new("router#", *events)
    @device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit", password: SecureRandom.hex(16),
                              transport: @transport, **options)
  end

  def with_log(mode)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      stream = StringIO.new
      options = if mode == :external
                  { logger: Logger.new(stream), log_level: :debug }
                else
                  { log_file: path, log_format: mode == :raw ? :raw : :text,
                    log_level: mode == :info ? :info : :debug }
                end
      contents = -> { mode == :external ? stream.string : File.binread(path) }
      yield options, contents, directory
    ensure
      @device&.close
    end
  end

  def assert_private_failure(result, logs = "")
    assert result.failure?
    error = result.error
    fields = [error.message, error.command, error.output, error.underlying&.message,
              error.underlying&.backtrace, error.full_message, logs]
    refute_includes fields.flatten.compact.map(&:b).join("\n"), @secret
    assert_nil error.cause
    raised = assert_raises(Connector::Error) { result.value! }
    refute_includes raised.full_message, @secret
  end
end
