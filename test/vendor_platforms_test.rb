# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "logger"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class VendorPlatformsTest < Minitest::Test
  PROMPTS = { topsec: "TopsecOS#", fortinet: "FGT-100F (root) # ", juniper: "audit@ex01> " }.freeze
  CONFIGS = {
    topsec: "system hostname set TopsecOS\nnetwork interface eth0 ip add 192.0.2.1/24\n",
    fortinet: "config system global\n    set hostname FGT-100F\nend\n",
    juniper: "set system host-name ex01\nset interfaces ge-0/0/0 description \"uplink core\"\n"
  }.freeze

  def teardown = @device&.close

  def test_platform_capabilities_are_explicit_without_opening_a_connection
    { topsec: [false, false, false, false], fortinet: [true, true, true, true],
      juniper: [false, false, true, true] }.each do |vendor, expected|
      build(vendor)
      assert @device.supports?(:backup)
      assert_equal expected, (%i[save_config tftp_backup neighbors interface_descriptions].map { |key| @device.supports?(key) })
      refute @device.supports?(:interface_description_changes)
      assert_equal 0, @transport.opens
      @device.close
    end
  end

  def test_configuration_collection_and_private_backup_use_current_platform_commands
    PROMPTS.each do |vendor, prompt|
      body = CONFIGS.fetch(vendor)
      command = Net::Connector.vendor_class(vendor).profile.config_commands.fetch(0)
      build(vendor, "#{command}\r\n#{body}#{prompt}", "#{command}\r\n#{body}#{prompt}")
      result = @device.running_config
      assert result.success?, result.error.inspect
      assert_includes result.value!, body.lines.first.strip
      assert(result.steps.all? { |step| step.command.output_sensitive? })
      Dir.mktmpdir do |directory|
        backup = @device.backup(path: File.join(directory, "configuration.cfg"))
        assert_equal result.value!, File.binread(backup.path)
        assert_equal 0o600, File.stat(backup.path).mode & 0o777
      end
      assert_equal ["#{command}\n"] * 2, @transport.writes
      @device.close
    end
  end

  def test_pagination_is_handled_without_persistent_terminal_setting_changes
    { fortinet: "--More--", juniper: "---(more 50%)---" }.each do |vendor, pager|
      prompt = PROMPTS.fetch(vendor)
      build(vendor, "first-line\r\n#{pager}", "last-line\r\n#{prompt}")
      result = @device.running_config
      assert result.success?, result.error.inspect
      assert_includes result.value!, "last-line"
      assert_equal " ", @transport.writes.last
      assert_equal 2, @transport.writes.size
      @device.close
    end
  end

  def test_device_errors_and_prompt_only_responses_cannot_be_backed_up
    { topsec: "Unknown command: show-running", fortinet: "Command fail. Return code -61",
      juniper: "error: permission denied" }.each do |vendor, diagnostic|
      build(vendor, "#{diagnostic}\n#{PROMPTS.fetch(vendor)}")
      result = @device.running_config
      assert result.failure?, vendor.to_s
      assert_instance_of Net::Connector::DeviceError, result.error
      @device.close
      command = Net::Connector.vendor_class(vendor).profile.config_commands.first
      build(vendor, "#{command}\r\n#{PROMPTS.fetch(vendor)}")
      result = @device.running_config
      assert result.failure?, vendor.to_s
      @device.close
    end
  end

  def test_configuration_output_never_enters_debug_log
    PROMPTS.each do |vendor, prompt|
      marker = "sensitive-configuration-body"
      log = StringIO.new
      build(vendor, "#{marker}\n#{prompt}", logger: Logger.new(log, level: Logger::DEBUG))
      assert_includes @device.running_config.value!, marker
      @device.close
      refute_includes log.string, marker
    end
  end

  def test_unsupported_native_exports_and_candidate_writes_do_not_open_sessions
    %i[topsec juniper].each do |vendor|
      build(vendor)
      assert_raises(Net::Connector::UnsupportedOperation) { @device.tftp_backup(host: "192.0.2.10") }
      assert @device.save_config.failure?
      assert_equal 0, @transport.opens
      @device.close
    end
    %i[topsec fortinet juniper].each do |vendor|
      build(vendor)
      assert_raises(Net::Connector::UnsupportedOperation) { @device.interfaces.sync }
      assert_equal 0, @transport.opens
      @device.close
    end
  end

  def test_fortinet_save_and_tftp_receipt_keep_export_semantics
    prompt = PROMPTS.fetch(:fortinet)
    build(:fortinet, "config saved.\n#{prompt}", "Send config file to tftp server OK.\n#{prompt}")
    assert @device.save_config.success?
    receipt = @device.tftp_backup(host: "192.0.2.10", path: "site/firewall.cfg")
    assert_equal :running, receipt.configuration_kind
    assert_equal :cfg, receipt.format
    assert_equal :device_reported, receipt.verification
    assert_equal "site/firewall.cfg", receipt.path
    assert_equal ["execute cfg save\n", "execute backup full-config tftp site/firewall.cfg 192.0.2.10\n"], @transport.writes
  end

  def test_fortinet_export_requires_explicit_completion_and_failure_takes_priority
    ["", "execute backup full-config tftp success.cfg 192.0.2.10\n", "Transfer complete.\n",
     "Send config file to tftp server OK.\nSend config file to tftp server failed.\n"].each do |output|
      build(:fortinet, "#{output}#{PROMPTS.fetch(:fortinet)}")
      error = assert_raises(Net::Connector::DeviceError) { @device.tftp_backup(host: "192.0.2.10", path: "success.cfg") }
      assert_equal output.include?("failed") ? :transfer_failed : :transfer_unconfirmed, error.code
      @device.close
    end
  end

  def test_fortinet_export_rejects_inapplicable_options_before_connecting
    [{ source_file: "startup.cfg" }, { vrf: "management" }, { path: "bad;command" }].each do |options|
      build(:fortinet)
      assert_raises(ArgumentError) { @device.tftp_backup(host: "192.0.2.10", **options) }
      assert_equal 0, @transport.opens
      @device.close
    end
  end

  def test_fortinet_lldp_uses_version_specific_dialect_and_rejects_partial_rows
    { "7.2.10" => "diagnose lldprx neighbor", "7.6.2" => "diagnose lldprx neighbor",
      "7.6.3" => "diagnose lldp rx neighbor", "8.0.0" => "diagnose lldp rx neighbor" }.each do |version, command|
      prompt = PROMPTS.fetch(:fortinet)
      build(:fortinet, "Version: FortiGate-100F v#{version},build1234\n#{prompt}",
            "1 port 'wan1' 5 mac 00:11:22:33:44:55 chassis 00:11:22:33:44:66 port 'Te1/0/1' system 'core01'\n#{prompt}")
      neighbor = @device.interfaces.neighbors.fetch(0)
      assert_equal ["wan1", "core01", "Te1/0/1", "00:11:22:33:44:66", :lldp], neighbor.to_h.values
      assert_equal ["get system status\n", "#{command}\n"], @transport.writes
      @device.close
    end
    build(:fortinet, "Version: unknown\n#{PROMPTS.fetch(:fortinet)}")
    assert_raises(Net::Connector::ParsingError) { @device.interfaces.neighbors }
    assert_equal ["get system status\n"], @transport.writes
    @device.close
    build(:fortinet, "Version: FortiGate v7.6.3,build1234\n#{PROMPTS.fetch(:fortinet)}",
          "1 port 'wan1' incomplete\n#{PROMPTS.fetch(:fortinet)}")
    assert_raises(Net::Connector::ParsingError) { @device.interfaces.neighbors }
  end

  def test_juniper_lldp_records_keep_interfaces_and_detect_missing_neighbors
    detail = <<~TEXT
      LLDP Neighbor Information:
      Local Interface : ge-0/0/0
      Parent Interface : ae0
      Chassis ID : 00:11:22:33:44:55
      Port ID : Ethernet1/1
      System name : core01.example
      Local Interface : xe-0/0/1
      Chassis ID : 00:11:22:33:44:66
      Port ID : Ethernet1/2
      System name : core02.example
    TEXT
    build(:juniper, "#{detail}#{PROMPTS.fetch(:juniper)}")
    assert_equal %w[ge-0/0/0 xe-0/0/1], @device.interfaces.neighbors.map(&:local_interface)
    @device.close
    build(:juniper, "#{detail}Local Interface : ge-0/0/3\n#{PROMPTS.fetch(:juniper)}")
    assert_raises(Net::Connector::ParsingError) { @device.interfaces.neighbors }
  end

  def test_juniper_management_port_does_not_replace_neighbor_port
    detail = "Local Interface : ge-0/0/0\nChassis ID : 00:11:22:33:44:55\n" \
             "Port ID : ge-0/0/1\nSystem name : edge01\nManagement Info\n  Port ID : 1\n" \
             "Local Interface : ge-0/0/2\nPort ID : xe-0/0/3\nSystem name : edge02\n"
    build(:juniper, "#{detail}#{PROMPTS.fetch(:juniper)}")
    assert_equal %w[ge-0/0/1 xe-0/0/3], @device.interfaces.neighbors.map(&:remote_interface)
  end

  def test_juniper_management_port_cannot_complete_a_partial_neighbor
    detail = "Local Interface : ge-0/0/0\nSystem name : edge01\nManagement Info\n  Port ID : 1\n"
    build(:juniper, "#{detail}#{PROMPTS.fetch(:juniper)}")
    assert_raises(Net::Connector::ParsingError) { @device.interfaces.neighbors }
  end

  def test_juniper_empty_neighbor_evidence_is_required
    ["", "LLDP Neighbor Information:\n"].each do |output|
      build(:juniper, "#{output}#{PROMPTS.fetch(:juniper)}")
      assert_raises(Net::Connector::ParsingError) { @device.interfaces.neighbors }
      @device.close
    end
    build(:juniper, "No LLDP neighbors\n#{PROMPTS.fetch(:juniper)}")
    assert_empty @device.interfaces.neighbors
  end

  def test_juniper_reads_physical_interface_descriptions_from_committed_set_configuration
    config = CONFIGS.fetch(:juniper) + "set interfaces xe-0/0/1 unit 0 family inet address 192.0.2.1/24\n"
    build(:juniper, "#{config}#{PROMPTS.fetch(:juniper)}")
    assert_equal({ "ge-0/0/0" => "uplink core", "xe-0/0/1" => "", "xe-0/0/1.0" => "" }, @device.interfaces.descriptions)
    @device.close
    build(:juniper, "set interfaces ge-0/0/0 description \"truncated\n#{PROMPTS.fetch(:juniper)}")
    assert_raises(Net::Connector::ParsingError) { @device.interfaces.descriptions }
  end

  def test_netdisco_resolves_supported_operating_systems_and_rejects_other_product_families
    rules = Net::Connector::Netdisco::Rules.new
    [{ "vendor" => "Topsec", "os" => "topos" }, { "vendor" => "Fortinet", "os" => "fortios" },
     { "vendor" => "Juniper Networks", "os" => "junos" }].zip(%i[topsec fortinet juniper]).each do |row, expected|
      assert_equal expected, rules.resolve(row)
    end
    assert_equal :fortinet, rules.resolve("vendor" => "FortiGate")
    assert_nil rules.resolve("vendor" => "Fortinet", "os" => "fortimail")
    assert_nil rules.resolve("vendor" => "Juniper", "os" => "screenos")
    assert_equal :juniper, Net::Connector::Netdisco::Rules.new(vendor_overrides: { "local label" => "juniper" }).resolve("vendor" => "local label")
  end

  private

  def build(vendor, *events, **options)
    @transport = ConnectorFake.new(PROMPTS.fetch(vendor), *events)
    @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: @transport, **options)
  end
end
