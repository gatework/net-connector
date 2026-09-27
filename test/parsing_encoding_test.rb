# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "securerandom"
require_relative "../lib/net/connector"
require_relative "../lib/net/connector/operations/saved_config"
require_relative "support/fake_transport"

class ParsingEncodingTest < Minitest::Test
  TEMPLATE = "cisco_ios_running_config_interfaces.textfsm"

  def setup
    @parser = Net::Connector::Operations::ParseOutput.new
  end

  def test_valid_utf8_bytes_and_terminal_controls_parse_without_changing_the_input
    text = "discarded\r\e[2Kinterface Ethernet1/1\r\n description 名称XX\b\b\e[K\r\n!\n".b.freeze
    original = text.dup
    assert_equal [{ "INTERFACE" => "Ethernet1/1", "DESCRIPTION" => "名称" }],
                 @parser.call(text, template: TEMPLATE)
    assert_equal original, text
    assert_equal Encoding::BINARY, text.encoding
  end

  def test_invalid_input_is_rejected_before_terminal_controls_can_escape_or_erase_it
    token = "encoding-#{SecureRandom.hex(8)}"
    ["#{token}\xFF", "#{token}\xFF\r\e[2K", "\e]0;#{token}\xFF\a"].each do |prefix|
      text = "#{prefix}\ninterface Ethernet1/1\n description uplink\n!\n".b.freeze
      error = assert_raises(Net::Connector::ParsingError) { @parser.call(text, template: TEMPLATE, host: "192.0.2.1") }
      assert_encoding_error(error, token)
      assert_equal "192.0.2.1", error.host
    end
  end

  def test_terminal_edits_that_split_a_multibyte_character_do_not_produce_parse_records
    text = "interface Ethernet1/1\n description 名\bX\n!\n"
    assert text.valid_encoding?
    error = assert_raises(Net::Connector::ParsingError) { @parser.call(text, template: TEMPLATE) }
    assert_encoding_error(error, "名")
    # 日志仍可显示非法字节；严格模式只用于解析副本。
    assert_includes Net::Connector::TerminalRenderer.render(text), "\\xE5\\x90X"
  end

  def test_non_utf8_saved_bytes_remain_exportable_but_are_not_silently_transcoded
    bytes = "interface Ethernet1/1\n description café\n!\n".encode(Encoding::ISO_8859_1)
    error = assert_raises(Net::Connector::ParsingError) { @parser.call(bytes, template: TEMPLATE) }
    assert_encoding_error(error, "café")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "192.0.2.1.txt")
      File.binwrite(path, bytes)
      reader = Net::Connector::Operations::SavedConfig.new(directory: directory)
      output = StringIO.new
      reader.export(host: "192.0.2.1", io: output)
      assert_equal bytes.b, output.string.b
      error = assert_raises(Net::Connector::ParsingError) { reader.parse(host: "192.0.2.1", template: TEMPLATE) }
      assert_encoding_error(error, "café")
      assert_equal bytes.b, File.binread(path)
    end
  end

  def test_command_parse_rejects_invalid_device_bytes_before_returning_records
    output = "interface Ethernet1/1\n description broken\xFF\n!\nrouter#".b
    transport = ConnectorFake.new("router#", output)
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "audit", transport: transport)
    error = assert_raises(Net::Connector::ParsingError) { device.parse_command("show fixture", template: TEMPLATE) }
    assert_encoding_error(error, "broken")
    assert_equal ["show fixture\n"], transport.writes
  ensure
    device&.close
  end

  def test_invalid_neighbors_cannot_become_empty_or_writable_topology_plans
    samples = {
      cisco_ios: "\xFF\r\e[2KTotal cdp entries displayed : 0\n",
      h3c: "\xFF\r\e[2KLocal Interface Chassis ID Port ID System Name\n"
    }
    samples.each do |vendor, output|
      commands = []
      device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: ConnectorFake.new)
      device.define_singleton_method(:execute) do |command|
        commands << command
        Net::Connector::Result.new(config: output)
      end
      device.define_singleton_method(:running_config) { raise "invalid neighbors must stop before config collection" }
      topology = Net::Connector::Operations::Topology.new(device)
      error = assert_raises(Net::Connector::ParsingError) { topology.plan_descriptions { "proposed" } }
      assert_encoding_error(error, "\xFF".b)
      assert_equal [device.profile.topology_strategy.new(device).neighbor_command], commands
    ensure
      device&.close
    end
  end

  private

  def assert_encoding_error(error, token)
    assert_equal :invalid_output_encoding, error.code
    assert_equal :parse, error.phase
    assert_empty error.output
    assert_nil error.underlying
    assert_nil error.cause
    refute_includes error.full_message.b, token.b
  end
end
