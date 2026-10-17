# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "logger"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class LineSeparatorTest < Minitest::Test
  Connector = Net::Connector

  def test_script_parsing_preserves_cli_lines_and_source_numbers
    [nil, "", "|"].each do |separator|
      script = with_separator(separator) { Connector::Script.parse("# note\r\nshow first\r\n\r\nshow second\n", name: "commands") }
      assert_equal ["show first", "show second"], script.map(&:text)
      assert_equal [2, 4], script.map(&:line)
    end
  end

  def test_palo_alto_rejects_a_non_set_line_after_a_valid_command
    device = Connector.build(:palo_alto, host: "192.0.2.1", username: "operator", transport: ConnectorFake.new)
    [nil, "", "|"].each do |separator|
      error = assert_raises(Connector::DeviceError) do
        with_separator(separator) { device.clean_config("set system host-name firewall\ninvalid command") }
      end
      assert_equal :unsupported_configuration_format, error.code
      text = "set system host-name firewall\nset description 'first\nsecond'"
      assert_equal text, with_separator(separator) { device.clean_config(text) }
    end
  ensure
    device&.close
  end

  def test_tftp_completion_separates_device_messages_from_command_echo
    Connector.vendor_class(:cisco_ios)
    strategy = Connector::Vendor::CiscoIos::Tftp.new(nil)
    command = Connector::Command.new("copy running-config tftp:")
    output = "#{command.text}\r\n123 bytes copied\r\nswitch#"
    step = Connector::Command::Result.new(command: command, output: output, prompt: "switch#", duration: 0)
    result = Connector::Result.new(steps: [step])
    [nil, "", "|"].each do |separator|
      assert with_separator(separator) { strategy.device_reported_complete?(result) }
      assert_equal ["123 bytes copied"] * 3, with_separator(separator) { strategy.failure_outputs(result).to_a }
    end
  end

  def test_logger_emits_one_event_per_device_line
    output = StringIO.new
    logger = Logger.new(output)
    events = []
    logger.formatter = ->(_severity, _time, _name, event) { events << event.to_h; "" }
    transport = ConnectorFake.new("router#", "first\nsecond\nrouter#")
    device = Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport,
                              logger: logger, log_level: :debug)
    result = with_separator(nil) { device.execute_command("show status") }
    assert result.success?, result.error.inspect
    lines = events.select { |event| event[:event] == "device_output" && event[:phase] == "command" }.filter_map { |event| event[:output] }
    assert_equal ["first", "second", "router#"], lines
  ensure
    device&.close
  end

  def test_stdin_credentials_leave_the_confirmation_line_unread
    settings = Object.new
    settings.define_singleton_method(:inventory) { |credentials:| credentials }
    values = { netdisco_username: "inventory", netdisco_password: "example-one",
               device_username: "operator", device_password: "example-two" }
    [nil, "", "|"].each do |separator|
      input = StringIO.new(JSON.generate(values) + "\nRUN\n")
      inventory, resolver = with_separator(separator) { Connector::Netdisco::CLI::Credentials.resolve(settings, stdin_credentials: true, input: input) }
      assert_equal "inventory", inventory.fetch(:username)
      assert_equal "operator", resolver.call(nil).fetch(:username)
      assert_equal "RUN\n", input.read
    end
  end

  def test_password_prompt_reads_exactly_one_line_with_echo_disabled
    [nil, "", "|"].each do |separator|
      input = StringIO.new("example-password\r\nnext input\n")
      input.define_singleton_method(:tty?) { true }
      hidden = false
      input.define_singleton_method(:noecho) { |&block| hidden = true; block.call(self) }
      output = StringIO.new
      options = with_separator(separator) do
        Connector::Netdisco::CLI::Options.parse(argv: ["--ask-password"], input: input, error: output)
      end
      assert hidden
      assert_equal "example-password", options.fetch(:environment).fetch("NC_DEVICE_PASSWORD")
      assert_equal "next input\n", input.read
      refute_includes output.string, "example-password"
    end
  end

  def test_transcript_strips_protocol_newlines_independently_of_record_separator
    lines = []
    transcript = Connector::Log.const_get(:Transcript, false).new { |line| lines << line }
    with_separator(nil) do
      transcript.write("first\r")
      transcript.write("\nsecond\nlast")
      transcript.finish
    end
    assert_equal ["first", "second", "last"], lines
  end

  private

  def with_separator(separator)
    previous, verbosity = $/, $VERBOSE
    $VERBOSE = nil
    $/ = separator
    yield
  ensure
    $/ = previous
    $VERBOSE = verbosity
  end
end
