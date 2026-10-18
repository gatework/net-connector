# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector"
require_relative "../lib/net/connector/storage/saved_config"
require_relative "support/fake_transport"

class TextfsmTest < Minitest::Test
  def test_h3c_command_index_uses_the_output_header_for_column_order
    parser = Net::Connector::TextFSM.new
    samples = ["Local Interface Chassis ID Port ID System Name\nGE1/0/1 0011-2233-4455 GE1/0/2 peer\n",
               "System Name Local Interface Chassis ID Port ID\npeer GE1/0/1 0011-2233-4455 GE1/0/2\n"]
    %i[h3c h3c_wireless].each do |vendor|
      samples.each do |sample|
        row = parser.call(sample, vendor: vendor, command: "display lldp neighbor-information list").fetch(0)
        assert_equal "GE1/0/1", row.fetch("LOCAL_INTERFACE")
        assert_equal "peer", row.fetch("NEIGHBOR_NAME")
      end
    end
  end

  def test_command_index_requires_complete_vendor_and_command_matches
    parser = Net::Connector::TextFSM.new
    [[:cisco_ios_other, "show ip interface brief"], [:cisco_ios, "prefix show ip interface brief"],
     [:cisco_ios, "show ip interface brief\n"]].each do |vendor, command|
      error = assert_raises(Net::Connector::ParsingError) { parser.call("", vendor: vendor, command: command) }
      assert_equal :template_missing, error.code
    end
  end

  def test_config_command_index_covers_each_implemented_description_dialect
    cases = {
      cisco_ios: ["show running-config", "interface Ethernet1\n description uplink\n!\n"],
      cisco_nxos: ["show running-config", "interface Ethernet1\n description uplink\n\n"],
      h3c: ["display current-configuration", "interface Ethernet1\n description uplink\n#\n"],
      h3c_wireless: ["dis cur", "interface Ethernet1\n description uplink\n#\n"],
      huawei: ["display current-configuration", "interface Ethernet1\n description uplink\n#\n"],
      hillstone: ["show configuration running", "interface Ethernet1\n description uplink\nexit\n"],
      palo_alto: ["show", "set network interface ethernet Ethernet1 comment uplink\n"],
      radware: ["/cfg/dump", "/cfg/port 1/name uplink"],
      fortinet: ["show full-configuration", "config system interface\n    edit Ethernet1\n        set description uplink\n    next\nend\n"],
      juniper: ["show configuration | display set | no-more", "set interfaces Ethernet1 description uplink\n"]
    }
    parser = Net::Connector::TextFSM.new
    cases.each do |vendor, (command, text)|
      rows = parser.call(text, vendor: vendor, command: command)
      assert_equal "uplink", rows.fetch(0).fetch("DESCRIPTION"), vendor.to_s
    end
  end

  def test_command_uses_vendor_and_command_index
    output = "Interface IP-Address OK? Method Status Protocol\r\n" \
      "GigabitEthernet0/0 192.0.2.1 YES manual up up\r\n" \
      "GigabitEthernet0/1 unassigned YES unset administratively down down\r\nrouter#"
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin",
                                  transport: ConnectorFake.new("router#", output))

    assert_equal [
                   { "INTERFACE" => "GigabitEthernet0/0", "IP_ADDRESS" => "192.0.2.1", "STATUS" => "up", "PROTOCOL" => "up" },
                   { "INTERFACE" => "GigabitEthernet0/1", "IP_ADDRESS" => "unassigned",
                     "STATUS" => "administratively down", "PROTOCOL" => "down" }
                 ], device.parse_command("show ip interface brief")
  ensure
    device&.close
  end

  def test_running_and_saved_config_use_the_same_explicit_template
    config = "hostname edge\ninterface GigabitEthernet0/0\n description uplink\n!\n" \
      "interface GigabitEthernet0/1\n shutdown\n!\n"
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: ConnectorFake.new)
    device.define_singleton_method(:running_config) { Net::Connector::Result.new(config: config) }
    expected = [
      { "INTERFACE" => "GigabitEthernet0/0", "DESCRIPTION" => "uplink" },
      { "INTERFACE" => "GigabitEthernet0/1", "DESCRIPTION" => "" }
    ]
    template = "cisco/show_running_config.textfsm"
    assert_equal expected, device.parse_config(template: template)

    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "192.0.2.1.txt"), config)
      saved = Net::Connector::Storage::SavedConfig.new(directory: directory)
      assert_equal expected, saved.parse(host: "192.0.2.1", template: template)
    end
  ensure
    device&.close
  end

  def test_custom_template_and_missing_template_have_distinct_results
    Dir.mktmpdir do |directory|
      template = File.join(directory, "status.textfsm")
      File.write(template, <<~'FSM')
        Value Required NAME (\S+)
        Value STATE (up|down)

        Start
          ^${NAME}\s+${STATE}$$ -> Record
      FSM
      parser = Net::Connector::TextFSM.new
      assert_equal [{ "NAME" => "port1", "STATE" => "up" }], parser.call("port1 up\n", template: template)
      assert_empty parser.call("other output\n", template: template)
      assert_equal [{ "NAME" => "port1", "STATE" => "up" }],
                   parser.call("\e[32mport1 up\e[0m\r\n", template: template)

      File.write(File.join(directory, "index"), "Template, Vendor, Command\nstatus.textfsm, h3c, display status$\n")
      custom = Net::Connector::TextFSM.new(template_dir: directory)
      assert_equal [{ "NAME" => "port1", "STATE" => "up" }],
                   custom.call("port1 up\n", vendor: :h3c, command: "display status")
      File.write(File.join(directory, "invalid_index"), "Vendor, Command\nh3c, display status\n")
      invalid = Net::Connector::TextFSM.new(template_dir: directory, index: "invalid_index")
      error = assert_raises(Net::Connector::ParsingError) do
        invalid.call("port1 up\n", vendor: :h3c, command: "display status")
      end
      assert_equal :template_invalid, error.code

      error = assert_raises(Net::Connector::ParsingError) do
        parser.call("secret password\n", vendor: :huawei, command: "display unknown")
      end
      assert_equal :template_missing, error.code
      refute_includes error.message, "secret password"
    end
  end

  def test_template_parse_error_does_not_expose_configuration
    Dir.mktmpdir do |directory|
      template = File.join(directory, "strict.textfsm")
      File.write(template, <<~'FSM')
        Value Required NAME (\S+)

        Start
          ^${NAME} -> Error "unexpected input"
      FSM
      parser = Net::Connector::TextFSM.new
      error = assert_raises(Net::Connector::ParsingError) do
        parser.call("private-password\n", template: template)
      end
      assert_equal :parse_failed, error.code
      refute_includes error.message, "private-password"
      assert_nil error.cause
    end
  end

  def test_command_error_is_preserved_instead_of_returning_empty_records
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin",
                                  transport: ConnectorFake.new("router#", "% Invalid input detected\nrouter#"))
    assert_raises(Net::Connector::DeviceError) { device.parse_command("show ip interface brief") }
  ensure
    device&.close
  end

  def test_parser_does_not_share_textfsm_state_between_threads
    parser = Net::Connector::TextFSM.new
    results = (1..12).map do |index|
      Thread.new do
        parser.call("GigabitEthernet0/#{index} 192.0.2.#{index} YES manual up up\n",
                    vendor: :cisco_ios, command: "show ip interface brief")
      end
    end.map(&:value)
    assert_equal((1..12).map { |index| "GigabitEthernet0/#{index}" },
                 results.map { |rows| rows.fetch(0).fetch("INTERFACE") })
  end
end
