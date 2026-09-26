# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "logger"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class ConnectorTest < Minitest::Test
  def test_all_vendor_profiles_load_and_expose_collection_commands
    assert_equal 8, Net::Connector.vendors.size
    Net::Connector.vendors.each do |vendor|
      klass = Net::Connector.vendor_class(vendor)
      assert_kind_of Net::Connector::Base, klass.new(host: "192.0.2.1", username: "admin",
                                                     transport: ConnectorFake.new)
      refute_empty klass.profile.config_commands
    end
    assert_equal Net::Connector.vendor_class(:cisco_nxos), Net::Connector.vendor_class(:cisco_n9k)
    assert_equal Net::Connector.vendor_class(:palo_alto), Net::Connector.vendor_class(:paloalto)
  end

  def test_vendor_connectors_delegate_backup_operations
    Net::Connector.vendors.each do |key|
      klass = Net::Connector.vendor_class(key)
      assert_equal key, klass.vendor
      refute_includes klass.instance_methods(false), :backup
      refute_includes klass.instance_methods(false), :tftp_backup
      assert klass.profile.tftp_strategy
    end
  end

  def test_script_stops_on_device_error_and_keeps_completed_steps
    transport = ConnectorFake.new("router#", "one\nrouter#", "% Incomplete command.\nrouter#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.execute_script(["first", "bad", "never"])

    assert result.failure?
    assert_equal(["first"], result.steps.map { |step| step.command.text })
    assert_instance_of Net::Connector::DeviceError, result.error
    assert_equal ["first\n", "bad\n"], transport.writes
    assert_equal 1, transport.closes
  ensure
    device&.close
  end

  def test_invalid_script_performs_no_io
    transport = ConnectorFake.new
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
    assert_raises(Net::Connector::ScriptError) { device.execute_script(["display version", "bad\ncommand"]) }
    assert_equal 0, transport.opens
  ensure
    device&.close
  end

  def test_backup_writes_private_file_and_does_not_replace_it_on_collection_failure
    Dir.mktmpdir do |directory|
      path = File.join(directory, "running.cfg")
      transport = ConnectorFake.new("<H3C>", "display current-configuration\nline one\n<H3C>")
      device = Net::Connector.build(:h3c_wireless, host: "192.0.2.1", username: "admin", transport: transport)
      backup = device.backup(path: path)
      assert_equal path, backup.path
      assert_equal File.size(path), backup.bytes
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_includes File.binread(path), "line one"
      original = File.binread(path)
      assert_raises(Net::Connector::LoginTimeout, Net::Connector::CommandTimeout) { device.backup(path: path) }
      assert_equal original, File.binread(path)
      device.close
    end
  end

  def test_backup_reports_changes_and_preserves_identical_file
    content = "hostname first\n"
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin",
                                  transport: ConnectorFake.new)
    device.define_singleton_method(:running_config) { Net::Connector::Result.new(config: content) }
    Dir.mktmpdir do |directory|
      path = File.join(directory, "switch.txt")
      first = device.backup(path: path)
      assert_equal :created, first.change
      assert first.changed?
      File.utime(Time.at(1), Time.at(1), path)

      second = device.backup(path: path)
      assert_equal :unchanged, second.change
      refute second.changed?
      assert_equal first.sha256, second.previous_sha256
      assert_equal Time.at(1), File.mtime(path)

      content = "hostname second\n"
      third = device.backup(path: path)
      assert_equal :changed, third.change
      assert_equal first.sha256, third.previous_sha256
      assert_equal content, File.read(path)
      File.chmod(0o644, path)
      fourth = device.backup(path: path)
      assert_equal :unchanged, fourth.change
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  ensure
    device&.close
  end

  def test_h3c_renders_terminal_carriage_returns_in_configuration
    raw = "#\r\nold-name\rnew-name\r\r\ninterface Vlan1\r\n"
    %i[h3c h3c_wireless huawei].each do |vendor|
      device = Net::Connector.build(vendor, host: "192.0.2.1", username: "admin",
                                    transport: ConnectorFake.new)
      assert_equal "#\nnew-name\ninterface Vlan1\n", device.clean_config(raw), vendor.to_s
      device.close
    end
  end

  def test_palo_alto_refuses_candidate_changes
    transport = ConnectorFake.new("admin@fw>", "admin@fw>", "admin@fw>",
                                  "show config diff\r\n+ candidate-only\r\nadmin@fw>")
    device = Net::Connector.build(:palo_alto, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.running_config
    assert result.failure?
    assert_equal :uncommitted_configuration, result.error.code
    refute_includes transport.writes, "configure\n"
  ensure
    device&.close
  end

  def test_open_closes_after_block
    transport = ConnectorFake.new("fw#")
    klass = Class.new(Net::Connector::Base) do
      profile do
        prompts do
          login(/fw#\z/)
          command(/fw#\z/)
        end
      end
    end
    assert_equal :done, klass.open(host: "192.0.2.1", username: "admin", transport: transport) { :done }
    assert_equal 1, transport.closes
  end

  def test_save_config_answers_cisco_confirmation
    transport = ConnectorFake.new("router#", "Destination filename [startup-config]?", "router#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.save_config
    assert result.success?, result.error&.message
    assert_equal ["copy running-config startup-config\n", "\n"], transport.writes
  ensure
    device&.close
  end

  def test_sensitive_interaction_is_not_written_to_session_log
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      klass = Class.new(Net::Connector::Base) do
        profile do
          prompts do
            login(/fw#\z/)
            command(/fw#\z/)
          end
        end
      end
      transport = ConnectorFake.new("fw#", "Token:", "secret-token\nfw#", "ordinary output\nfw#")
      device = klass.new(host: "192.0.2.1", username: "admin", transport: transport, log_file: path,
                         log_level: :debug)
      interaction = Net::Connector::Interaction.new(/Token:\z/, "secret-token\n", sensitive: true)
      assert device.execute("verify", interactions: [interaction]).success?
      assert device.execute("show status").success?
      device.close
      log = File.binread(path)
      refute_includes log, "secret-token"
      assert_includes log, "ordinary output"
      refute File.exist?("#{path}.transcript")
    end
  end

  def test_session_log_records_login_and_command_boundaries_with_full_device_output
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      transport = ConnectorFake.new("Password:", "secret-password\nfw#",
                                    "show status\r\nline one\r\nline two\r\nfw#")
      klass = Class.new(Net::Connector::Base) do
        profile do
          prompts do
            login(/fw#\z/)
            command(/fw#\z/)
          end
        end
      end
      device = klass.new(host: "192.0.2.1", username: "admin", password: "secret-password",
                         transport: transport, log_file: path, log_level: :debug)
      assert device.execute("show status").success?
      device.close
      log = File.read(path, encoding: Encoding::UTF_8)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_match(/开始连接 192\.0\.2\.1（FAKE，账号 admin）/, log)
      assert_match(/等待设备登录提示/, log)
      assert_match(/登录过程回显（已脱敏）/, log)
      assert_match(/Password:/, log)
      assert_match(/登录成功，设备提示符：fw#/, log)
      assert_match(/下发命令：show status/, log)
      assert_match(/设备回显：/, log)
      assert_match(/show status\nline one\nline two/, log)
      assert_match(/命令回显结束，已收到设备提示符/, log)
      assert_match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{2}:\d{2}\] INFO \[host=192\.0\.2\.1\] /, log)
      refute_includes log, '"status"'
      refute_includes log, "secret-password"
      refute File.exist?("#{path}.transcript")
    end
  end

  def test_injected_logger_receives_tagged_events_without_being_closed_or_reconfigured
    output = StringIO.new
    logger = ::Logger.new(output)
    logger.level = ::Logger::INFO
    transport = ConnectorFake.new("fw#", "device detail\nfw#")
    klass = Class.new(Net::Connector::Base) do
      profile do
        prompts do
          login(/fw#\z/)
          command(/fw#\z/)
        end
      end
    end
    device = klass.new(host: "192.0.2.1", username: "admin", transport: transport,
                       logger: logger, log_level: :debug)
    assert device.execute("show status").success?
    device.close
    assert_equal ::Logger::INFO, logger.level
    assert_match(/\[host=192\.0\.2\.1\] 开始连接/, output.string)
    refute_includes output.string, "device detail"
    logger.info("caller logger still open")
    assert_includes output.string, "caller logger still open"
  end

  def test_debug_injected_logger_includes_device_output_in_same_stream
    output = StringIO.new
    logger = ::Logger.new(output)
    logger.level = ::Logger::DEBUG
    transport = ConnectorFake.new("fw#", "show status\r\nready\r\nfw#")
    klass = Class.new(Net::Connector::Base) do
      profile do
        prompts do
          login(/fw#\z/)
          command(/fw#\z/)
        end
      end
    end
    device = klass.new(host: "192.0.2.2", username: "admin", transport: transport,
                       logger: logger, log_level: :debug)
    assert device.execute("show status").success?
    device.close
    assert_match(/\[host=192\.0\.2\.2\]\s+ready/, output.string)
  end

  def test_session_log_records_login_failure_without_credentials
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      transport = ConnectorFake.new(:timeout)
      device = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin",
                                    password: "secret-password", transport: transport, log_file: path,
                                    log_level: :debug)
      assert_raises(Net::Connector::LoginTimeout) { device.connect }
      log = File.read(path, encoding: Encoding::UTF_8)
      assert_match(/等待设备登录提示/, log)
      assert_match(/ERROR \[host=192\.0\.2\.1\] 登录失败：/, log)
      refute_includes log, "secret-password"
    end
  end

  def test_info_log_keeps_key_events_without_debug_transcript
    Dir.mktmpdir do |directory|
      path = File.join(directory, "session.log")
      transport = ConnectorFake.new("fw#", "device detail\nfw#")
      klass = Class.new(Net::Connector::Base) do
        profile do
          prompts do
            login(/fw#\z/)
            command(/fw#\z/)
          end
        end
      end
      device = klass.new(host: "192.0.2.1", username: "admin", transport: transport,
                         log_file: path, log_level: :info)
      assert device.execute("show status").success?
      device.close
      log = File.read(path, encoding: Encoding::UTF_8)
      assert_match(/INFO \[host=192\.0\.2\.1\] 开始连接/, log)
      assert_match(/INFO \[host=192\.0\.2\.1\] 登录成功/, log)
      assert_match(/INFO \[host=192\.0\.2\.1\] 下发命令/, log)
      assert_match(/INFO \[host=192\.0\.2\.1\] 命令回显结束/, log)
      refute_includes log, "device detail"
      refute File.exist?("#{path}.transcript")
      refute_includes log, "登录过程回显"
      refute_includes log, "命令耗时"
      assert_raises(ArgumentError) { Net::Connector::Configuration.new(log_level: :verbose) }
    end
  end

  def test_tftp_log_distinguishes_device_reported_upload_from_transfer_failure
    Dir.mktmpdir do |directory|
      success_path = File.join(directory, "success.log")
      success = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin",
                                     transport: ConnectorFake.new("fw#", "Export ok,target file name fw.dat\nfw#"),
                                     log_file: success_path)
      success.tftp_backup(host: "192.0.2.10", path: "fw.dat")
      success.close
      assert_match(/INFO \[host=192\.0\.2\.1\] TFTP 备份：设备报告上传成功，目标 192\.0\.2\.10\/fw\.dat；服务器文件尚未核验/,
                   File.read(success_path, encoding: Encoding::UTF_8))

      failure_path = File.join(directory, "failure.log")
      failure = Net::Connector.build(:hillstone, host: "192.0.2.2", username: "admin",
                                     transport: ConnectorFake.new("fw#", "tftp: timeout\nfw#"),
                                     log_file: failure_path, log_level: :error)
      assert_raises(Net::Connector::DeviceError) do
        failure.tftp_backup(host: "192.0.2.10", path: "fw.dat")
      end
      failure.close
      log = File.read(failure_path, encoding: Encoding::UTF_8)
      assert_match(/ERROR \[host=192\.0\.2\.2\] TFTP 备份失败：设备报告传输失败/, log)
      refute_match(/INFO 开始连接/, log)
    end
  end

  def test_palo_alto_requires_sent_bytes_not_just_tftp_connection
    transport = ConnectorFake.new("careline@SZX8-FW01(active)>",
                                  "mode set to octet\r\nConnected to 192.0.2.10, port 69\r\n" \
                                    "putting running-config.xml\r\ncareline@SZX8-FW01(active)>")
    device = Net::Connector.build(:palo_alto, host: "192.0.2.1", username: "admin", transport: transport)
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10")
    end
    assert_equal :transfer_unconfirmed, error.code
  ensure
    device&.close
  end

  def test_h3c_accepts_completed_carriage_return_progress
    output = "Press CTRL+C to abort.\r  % Total  % Received  % Xferd\r" \
      "100  9664    0     0  100  9664      0  14687\r\n<H3C>"
    transport = ConnectorFake.new("<H3C>", output)
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
    backup = device.tftp_backup(host: "192.0.2.10", path: "switch.cfg",
                                source_file: "flash:/startup.cfg")
    assert_equal "switch.cfg", backup.path
  ensure
    device&.close
  end

  def test_h3c_missing_startup_file_is_transfer_failure
    transport = ConnectorFake.new("<H3C>", "Can't open flash:/startup.cfg!\r\n<H3C>")
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", source_file: "flash:/startup.cfg")
    end
    assert_equal :transfer_failed, error.code
  ensure
    device&.close
  end

  def test_h3c_discovers_startup_file_on_other_storage_device
    startup = "Current startup saved-configuration file: cfa0:/startup.cfg(*)\r\n" \
      "Next main startup saved-configuration file: cfa0:/startup.cfg\r\n<H3C>"
    transfer = "100  9664    0     0  100  9664      0  14687\r\n<H3C>"
    transport = ConnectorFake.new("<H3C>", startup, transfer)
    device = Net::Connector.build(:h3c_wireless, host: "192.0.2.1", username: "admin", transport: transport)
    backup = device.tftp_backup(host: "192.0.2.10", path: "switch.cfg")
    assert_equal "switch.cfg", backup.path
    assert_includes transport.writes, "display startup\n"
    assert_includes transport.writes, "tftp 192.0.2.10 put cfa0:/startup.cfg switch.cfg\n"
  ensure
    device&.close
  end

  def test_h3c_accepts_completed_progress_with_human_size
    transport = ConnectorFake.new("<H3C>",
                                  "100  110k    0     0  100  110k      0  15764\r\n<H3C>")
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
    backup = device.tftp_backup(host: "192.0.2.10", path: "switch.cfg",
                                source_file: "cfa0:/startup.cfg")
    assert_equal "switch.cfg", backup.path
  ensure
    device&.close
  end

  def test_tftp_backup_uses_vendor_commands_and_requires_transfer_evidence
    cases = {
      h3c: ["<H3C>", "tftp 192.0.2.10 put flash:/startup.cfg switch.cfg\r\nTransfer complete.\r\n<H3C>",
            "tftp 192.0.2.10 put flash:/startup.cfg switch.cfg\n", "flash:/startup.cfg"],
      h3c_wireless: ["<H3C>", "Transfer complete.\r\n<H3C>",
                     "tftp 192.0.2.10 put flash:/startup.cfg switch.cfg\n", "flash:/startup.cfg"],
      huawei: ["<HUAWEI>", "Transfer completed successfully\r\n<HUAWEI>",
               "tftp 192.0.2.10 put flash:/startup.cfg switch.cfg\n", "flash:/startup.cfg"],
      cisco_ios: ["router#", "100 bytes copied\r\nrouter#",
                  "copy running-config tftp:\n", nil],
      cisco_nxos: ["switch#", "Copy complete\r\nswitch#",
                   "copy running-config tftp://192.0.2.10/switch.cfg vrf management\n", nil],
      radware: [">> Main#", "Current config successfully tftp'd\r\n>> Main#",
                "/cfg/ptcfg 192.0.2.10 -tftp\n", nil],
      palo_alto: ["admin@fw>", "Sent 983442 bytes in 21.2 seconds\r\nadmin@fw>",
                  "tftp export configuration to 192.0.2.10 from running-config.xml\n", nil],
      hillstone: ["SZX8-MG-FW01#", "Export ok,target file name switch.cfg\r\nSZX8-MG-FW01#",
                  "export configuration startup to tftp server 192.0.2.10 vrouter mgt-vr switch.cfg\n", nil]
    }
    cases.each do |vendor, (login, output, write, source_file)|
      path = vendor == :palo_alto ? "running-config.xml" : "switch.cfg"
      events = if vendor == :radware
                 [login, "Enter hostname or IP address of FTP/TFTP/SCP server:",
                  "Enter name of file on FTP/TFTP/SCP server:",
                  "Enter username for FTP/SCP server or hit return for TFTP server:", output]
               else
                 [login, output]
               end
      transport = ConnectorFake.new(*events)
      device = Net::Connector.build(vendor, host: "192.0.2.1", username: "admin", transport: transport)
      result = device.tftp_backup(host: "192.0.2.10", path: path, source_file: source_file)
      assert_equal "192.0.2.10", result.server, vendor.to_s
      assert_equal path, result.path, vendor.to_s
      assert_includes transport.writes, write, vendor.to_s
      device.close
    rescue Net::Connector::Error => error
      flunk "#{vendor}: #{error.code}"
    end
  end

  def test_tftp_backup_rejects_unsafe_inputs_and_unconfirmed_transfer
    transport = ConnectorFake.new("router#", "router#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport)
    assert_raises(ArgumentError) { device.tftp_backup(host: "192.0.2.10", path: "../escape") }
    assert_equal 0, transport.opens
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.cfg")
    end
    assert_equal :transfer_unconfirmed, error.code
  ensure
    device&.close
  end

  def test_huawei_tftp_backup_defaults_to_source_filename_without_destination_argument
    transport = ConnectorFake.new("<SZX9-CSW01>",
                                  "Transfer completed successfully\r\n<SZX9-CSW01>")
    device = Net::Connector.build(:huawei, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.tftp_backup(host: "192.0.2.253", source_file: "flash:/startup.cfg")
    assert_equal "startup.cfg", result.path
    assert_equal ["tftp 192.0.2.253 put flash:/startup.cfg\n"], transport.writes
  ensure
    device&.close
  end

  def test_tftp_backup_failure_text_overrides_success_text
    transport = ConnectorFake.new("router#", "100 bytes copied; transfer failed\r\nrouter#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport)
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.cfg")
    end
    assert_equal :transfer_failed, error.code
  ensure
    device&.close
  end

  def test_h3c_tftp_curl_progress_is_transfer_evidence_but_timeout_is_not
    progress = "  % Total    % Received % Xferd\r\n100  8691    0     0  100  8691\r\n"
    transport = ConnectorFake.new("<H3C>", "#{progress}<H3C>")
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.tftp_backup(host: "192.0.2.10", path: "switch.cfg", source_file: "flash:/startup.cfg")
    assert_equal "switch.cfg", result.path
    device.close

    transport = ConnectorFake.new("<H3C>", "#{progress}Timeout was reached\r\n<H3C>")
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: transport)
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.cfg", source_file: "flash:/startup.cfg")
    end
    assert_equal :transfer_failed, error.code
  ensure
    device&.close
  end

  def test_nxos_tftp_answers_vrf_prompt_and_rejects_transfer_timeout
    transport = ConnectorFake.new("switch#",
                                  "Enter vrf (If no input, current vrf 'default' is considered):",
                                  "Connection to Server Established.\r\nTFTP put operation failed:Connection timed out\r\nswitch#")
    device = Net::Connector.build(:cisco_nxos, host: "192.0.2.1", username: "admin", transport: transport)
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.cfg")
    end
    assert_equal :transfer_failed, error.code
    assert_includes transport.writes, "copy running-config tftp://192.0.2.10/switch.cfg vrf management\n"
    assert_includes transport.writes, "management\n"
  ensure
    device&.close
  end

  def test_ios_tftp_answers_host_and_destination_prompts
    transport = ConnectorFake.new("router#",
                                  "Address or name of remote host [192.0.2.10]?",
                                  "Destination filename [router-confg]?",
                                  "1280 bytes copied in 2.1 secs\r\nrouter#")
    device = Net::Connector.build(:cisco_ios, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.tftp_backup(host: "192.0.2.10", path: "router.cfg")
    assert_equal "router.cfg", result.path
    assert_includes transport.writes, "192.0.2.10\n"
    assert_includes transport.writes, "router.cfg\n"
  ensure
    device&.close
  end

  def test_nxos_tftp_vrf_override_is_validated_before_io
    transport = ConnectorFake.new("switch#", "Copy complete\r\nswitch#")
    device = Net::Connector.build(:cisco_nxos, host: "192.0.2.1", username: "admin", transport: transport)
    assert_raises(ArgumentError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.cfg", vrf: "management;reload")
    end
    assert_equal 0, transport.opens
    device.tftp_backup(host: "192.0.2.10", path: "switch.cfg", vrf: "backup")
    assert_includes transport.writes, "copy running-config tftp://192.0.2.10/switch.cfg vrf backup\n"
  ensure
    device&.close
  end

  def test_radware_tftp_uses_native_tgz_prompt
    transport = ConnectorFake.new(">> Main#",
                                  "Enter hostname (and IP version) or IP address of FTP/TFTP/SCP server:",
                                  "Enter name of .tgz file and path on FTP/TFTP/SCP server or hit return for automatic file name:",
                                  "Include private keys? [y/n]:",
                                  'Enter "mansync" to get real/group/virt internal index config:',
                                  "Current config successfully tftp'd\r\n>> Main#")
    device = Net::Connector.build(:radware, host: "192.0.2.1", username: "admin", transport: transport)
    result = device.tftp_backup(host: "192.0.2.10", path: "switch.tgz")
    assert_equal "switch.tgz", result.path
    assert_includes transport.writes, "switch.tgz\n"
    assert_includes transport.writes, "n\n"
    assert_includes transport.writes, "mansync\n"
  ensure
    device&.close
  end

  def test_hillstone_collects_running_config_and_rejects_unconfirmed_tftp
    assert_equal ["terminal length 0", "show configuration running"],
                 Net::Connector.vendor_class(:hillstone).profile.config_commands
    transport = ConnectorFake.new("SZX8-MG-FW01#",
                                  "tftp: sendto: Network is unreachable\r\nSZX8-MG-FW01#")
    device = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin", transport: transport)
    assert_raises(ArgumentError) do
      device.tftp_backup(host: "192.0.2.10", path: "site/switch.cfg")
    end
    assert_equal 0, transport.opens
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.cfg")
    end
    assert_equal :transfer_failed, error.code
  ensure
    device&.close
  end

  def test_hillstone_uses_device_generated_filename_when_no_path_is_given
    output = "SZX8-MG-FW01-CONFIG. 100% |***| 43263 0:00:00 ETA\r\n" \
      "Export ok,target file name SZX8-MG-FW01-CONFIG.Startup-202609181558.dat\r\nSZX8-MG-FW01#"
    transport = ConnectorFake.new("SZX8-MG-FW01#", output)
    device = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin", transport: transport)
    backup = device.tftp_backup(host: "192.0.2.10")
    assert_equal "SZX8-MG-FW01-CONFIG.Startup-202609181558.dat", backup.path
    assert_includes transport.writes,
                    "export configuration startup to tftp server 192.0.2.10 vrouter mgt-vr\n"
  ensure
    device&.close
  end

  def test_hillstone_accepts_vrf_override_and_validates_it
    transport = ConnectorFake.new("SZX8-VPN-FW01(M)#",
                                  "Export ok,target file name SZX8-VPN-FW01-192.0.2.1.dat\r\n" \
                                    "SZX8-VPN-FW01(M)#")
    device = Net::Connector.build(:hillstone, host: "192.0.2.1", username: "admin", transport: transport)
    assert_raises(ArgumentError) do
      device.tftp_backup(host: "192.0.2.10", path: "SZX8-VPN-FW01-192.0.2.1.dat", vrf: "bad;vr")
    end
    assert_equal 0, transport.opens
    backup = device.tftp_backup(host: "192.0.2.10", path: "SZX8-VPN-FW01-192.0.2.1.dat",
                                vrf: "management")
    assert_equal "SZX8-VPN-FW01-192.0.2.1.dat", backup.path
    assert_includes transport.writes,
                    "export configuration startup to tftp server 192.0.2.10 vrouter management SZX8-VPN-FW01-192.0.2.1.dat\n"
  ensure
    device&.close
  end

  def test_radware_tftp_timeout_is_explicit_failure
    transport = ConnectorFake.new(">> Standalone ADC - Main#",
                                  "Enter name of .tgz file and path on FTP/TFTP/SCP server or hit return for automatic file name:",
                                  "Include private keys? [y/n]:",
                                  'Enter "mansync" to get real/group/virt internal index config:',
                                  "Preparing configuration file. Please wait.\r\nConnecting to 192.0.2.10...\r\n" \
                                    "Error: Timeout.\r\n>> Standalone ADC - Configuration#")
    device = Net::Connector.build(:radware, host: "192.0.2.1", username: "admin", transport: transport)
    error = assert_raises(Net::Connector::DeviceError) do
      device.tftp_backup(host: "192.0.2.10", path: "switch.tgz")
    end
    assert_equal :transfer_failed, error.code
  ensure
    device&.close
  end

  def test_tftp_backup_rejects_unsafe_source_and_palo_alto_filename_before_io
    h3c_transport = ConnectorFake.new
    h3c = Net::Connector.build(:h3c, host: "192.0.2.1", username: "admin", transport: h3c_transport)
    assert_raises(ArgumentError) { h3c.tftp_backup(host: "192.0.2.10", path: "../escape") }
    assert_raises(ArgumentError) { h3c.tftp_backup(host: "bad;host") }
    assert_raises(ArgumentError) do
      h3c.tftp_backup(host: "192.0.2.10", source_file: "flash:/../startup.cfg")
    end
    assert_equal 0, h3c_transport.opens

    palo_transport = ConnectorFake.new
    palo = Net::Connector.build(:palo_alto, host: "192.0.2.2", username: "admin", transport: palo_transport)
    assert_raises(ArgumentError) { palo.tftp_backup(host: "192.0.2.10", path: "other.xml") }
    assert_equal 0, palo_transport.opens
  ensure
    h3c&.close
    palo&.close
  end
end
