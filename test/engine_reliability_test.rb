# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "logger"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class EngineReliabilityTest < Minitest::Test
  def test_nonexception_exit_from_device_dialogue_closes_the_incomplete_session
    transport = ConnectorFake.new("router#", "Destination filename:", "router#", "router#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport)
    interaction = Net::Connector::Interaction.new(/Destination filename:\z/, ->(_) { throw :cancel, :cancelled })
    outcome = catch(:cancel) do
      device.execute("copy running-config flash:", interactions: [interaction])
      :not_cancelled
    end

    assert_equal :cancelled, outcome
    refute device.connected?
    assert_equal 1, transport.closes
    assert device.execute("show version").success?
    assert_equal 2, transport.opens
  ensure
    device&.close
  end

  def test_command_diagnostics_recognize_color_without_erasing_raw_failure
    ["\e[31m% Invalid input\e[0m\n", "% Invalid input\rcleared\e[K\n"].each do |output|
      device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin",
                                    transport: ConnectorFake.new("router#", "#{output}router#"))
      result = device.execute("show broken")
      assert_instance_of Net::Connector::DeviceError, result.error
      assert_includes result.error.message, "% Invalid input"
      assert_empty result.steps
      refute device.connected?
    ensure
      device&.close
    end
  end

  def test_log_open_failure_closes_the_file_before_returning
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      file = File.open(path, "w")
      file.define_singleton_method(:chmod) { |_| raise IOError, "mode change failed" }
      log = Net::Connector::Log.new(Net::Connector::Configuration.new(log_file: path),
                                    redactor: Net::Connector::Redactor.new)
      File.stub(:open, file) do
        assert_raises(Net::Connector::LogError) { log.open(ConnectorFake.new) }
      end
      assert file.closed?, "log owns and must release a file even when setup fails"
    ensure
      file&.close
    end
  end

  def test_log_close_releases_state_after_a_flush_failure
    Dir.mktmpdir do |directory|
      configuration = Net::Connector::Configuration.new(log_file: File.join(directory, "session.log"), log_format: :raw)
      log = Net::Connector::Log.new(configuration, redactor: Net::Connector::Redactor.new)
      transport = ConnectorFake.new
      log.open(transport)
      log.attach
      file = log.instance_variable_get(:@io)
      file.define_singleton_method(:flush) { raise IOError, "flush failed" }

      assert_raises(Net::Connector::LogError) { log.close }
      assert file.closed?
      log.close
      assert_nil transport.log_output
    end
  end

  def test_application_logger_redacts_secrets_reconstructed_by_terminal_controls
    output = StringIO.new
    configuration = Net::Connector::Configuration.new(logger: ::Logger.new(output), log_level: :debug)
    log = Net::Connector::Log.new(configuration, redactor: Net::Connector::Redactor.new("secret-token"))
    log.open(ConnectorFake.new)
    log.response_output("secret-tokXX\b\ben\n")
    log.close
    refute_includes output.string, "secret-token"
    assert_includes output.string, "[REDACTED]"
  end

  def test_raw_string_format_rejects_an_application_logger
    logger = ::Logger.new(StringIO.new)
    assert_raises(ArgumentError) { Net::Connector::Configuration.new(logger: logger, log_format: "raw") }
  end

  def test_file_logs_redact_credentials_across_chunks_and_flush_the_tail
    %i[text raw].each do |format|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "session.log")
        transport = ConnectorFake.new("router#", "config sec", "ret-token\nrouter#")
        device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin",
                                      password: "secret-token", transport: transport,
                                      log_file: path, log_format: format, log_level: :debug)
        assert device.execute("show").success?
        device.close
        contents = File.binread(path)
        refute_includes contents, "secret-token", format.to_s
        assert_includes contents, "config [REDACTED]", format.to_s
        assert_includes contents, "router#", format.to_s
      ensure
        device&.close
      end
    end
  end

  def test_sensitive_pause_finishes_previous_output_without_recording_the_secret
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      configuration = Net::Connector::Configuration.new(log_file: path, log_format: :raw)
      log = Net::Connector::Log.new(configuration, redactor: Net::Connector::Redactor.new("secret-token"))
      transport = ConnectorFake.new
      log.open(transport)
      log.attach
      log.write("sec")
      log.pause do
        assert_nil transport.log_output
        assert_equal "sec", File.binread(path)
      end
      log.write("ordinary output")
      log.close
      assert_equal "secordinary output", File.binread(path)
    end
  end

  def test_streaming_redaction_handles_every_secret_split_and_terminal_overwrites
    %i[text raw].each do |format|
      (1...("secret-token".bytesize)).each do |split|
        Dir.mktmpdir do |directory|
          path = File.join(directory, "session.log")
          configuration = Net::Connector::Configuration.new(log_file: path, log_format: format, log_level: :debug)
          log = Net::Connector::Log.new(configuration, redactor: Net::Connector::Redactor.new("secret-token"))
          log.open(ConnectorFake.new)
          log.write("prefix " + "secret-token".byteslice(0, split))
          log.flush
          log.write("secret-token".byteslice(split..) + (" suffix" * 20) + "\n")
          log.event("boundary")
          log.write("secret-tokXX\b\ben\n") if format == :text
          log.close
          contents = File.binread(path)
          refute_includes contents, "secret-token"
          assert_includes contents, "prefix [REDACTED] suffix"
          assert_equal(format == :text ? 2 : 1, contents.scan("[REDACTED]").size)
          if format == :text
            assert_operator contents.index("suffix\n"), :<, contents.index("boundary")
          end
        end
      end
    end
  end

  def test_reconnection_closes_the_previous_log_file
    Dir.mktmpdir do |directory|
      transport = ConnectorFake.new("router#", "router#", "router#", "router#")
      device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport,
                                    log_file: File.join(directory, "session.log"))
      assert device.execute("show").success?
      log = device.instance_variable_get(:@session).instance_variable_get(:@log)
      previous_file = log.instance_variable_get(:@io)
      transport.close
      assert device.execute("show").success?
      assert previous_file.closed?
      device.close
    ensure
      device&.close
    end
  end

  def test_reconnection_discards_privilege_from_the_previous_transport
    transport = ConnectorFake.new("<Huawei>", "privilege level is 3\n<Huawei>", "first\n<Huawei>",
                                  "<Huawei>", "privilege level is 3\n<Huawei>", "second\n<Huawei>")
    device = Net::Connector.build(:huawei, host: "192.0.2.1", username: "admin", transport: transport)
    assert device.execute("display version").success?
    transport.close
    assert device.execute("display version").success?
    assert_equal ["su\n", "display version\n", "su\n", "display version\n"], transport.writes
  ensure
    device&.close
  end
end
