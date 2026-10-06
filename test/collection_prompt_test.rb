# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class CollectionPromptTest < Minitest::Test
  def teardown = @device&.close

  def collection(vendor, tail: true)
    prompt = %i[h3c h3c_wireless huawei].include?(vendor) ? "[switch]" : "switch#"
    deceptive = prompt.start_with?("[") ? " description [uplink]" : " description uplink#"
    events = [prompt]
    commands = Net::Connector.vendor_class(vendor).profile.config_commands
    (commands.size - 1).times { events << prompt }
    events << "#{commands.last}\r\ninterface Ethernet1/1\r\n#{deceptive}"
    events << "\r\ninterface Ethernet1/2\r\n description final-interface\r\n#{prompt}" if tail
    @transport = ConnectorFake.new(*events)
    @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: @transport)
  end

  def test_configuration_descriptions_do_not_complete_collection
    %i[cisco_nxos h3c h3c_wireless huawei].each do |vendor|
      collection(vendor)
      result = @device.running_config
      assert result.success?, "#{vendor}: #{result.error.inspect}"
      assert_includes result.config, "description final-interface", vendor.to_s
      assert_empty @transport.events
      @device.close
    end
  end

  def test_other_device_prompt_in_configuration_does_not_complete_collection
    collection(:cisco_nxos)
    @transport.events[2] = "interface Ethernet1/1\r\nother-switch#"
    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_includes result.config, "description final-interface"
  end

  def test_missing_real_prompt_does_not_replace_existing_backup
    Dir.mktmpdir do |directory|
      path = File.join(directory, "switch.cfg")
      File.write(path, "previous complete configuration")
      collection(:cisco_nxos, tail: false)
      assert_raises(Net::Connector::CommandTimeout) { @device.backup(path: path) }
      assert_equal "previous complete configuration", File.read(path)
      refute @device.connected?
    end
  end

  def test_confirmed_tail_is_saved_instead_of_truncated_content
    Dir.mktmpdir do |directory|
      path = File.join(directory, "switch.cfg")
      File.write(path, "previous complete configuration")
      collection(:cisco_nxos)
      backup = @device.backup(path: path)
      assert_equal :changed, backup.change
      assert_includes File.read(path), "description final-interface"
    end
  end

  def test_cisco_backup_preserves_command_and_progress_examples_inside_a_banner
    %i[cisco_ios cisco_nxos].each do |vendor|
      body = <<~CONFIG
        hostname switch
        banner motd @
        switch#terminal length 0
        switch#show running-config
        switch#copy running-config startup-config
        ! Last configuration change is an example
        ! NVRAM config is an example
        ] 100%
        Copy complete.
        @
        interface Ethernet1/2
         description final-interface
        end
      CONFIG
      transport = ConnectorFake.new("switch#", "switch#", "#{body}switch#")
      @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: transport)
      Dir.mktmpdir do |directory|
        path = File.join(directory, "switch.cfg")
        File.write(path, "previous complete configuration")
        backup = @device.backup(path: path)
        assert_equal :changed, backup.change
        assert_equal "#{body}switch#", File.binread(path), vendor.to_s
        assert_equal ["terminal length 0\n", "show running-config\n"], transport.writes
      end
      @device.close
    end
  end

  def test_cisco_cleaning_only_removes_volatile_comments_from_the_response_header
    %i[cisco_ios cisco_nxos].each do |vendor|
      @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: ConnectorFake.new)
      header = "show running-config\nBuilding configuration...\n\nCurrent configuration : 123 bytes\n!\n"
      volatile = "! Last configuration change at 12:00\n! NVRAM config last updated at 12:00\n"
      body = "hostname switch\nbanner motd @\n#{volatile}@\nend\nswitch#"
      assert_equal "#{header}#{body}", @device.clean_config("#{header}#{volatile}#{body}"), vendor.to_s
      @device.close
    end
  end

  class LocalTransport < Net::Connector::Transports::Pty
    attr_reader :channel

    def initialize(configuration, script)
      super(configuration)
      @script = script
    end

    def argv = [RbConfig.ruby, "--disable-gems", "-e", @script]
  end

  def test_real_pty_waits_for_the_device_prompt_after_a_delayed_fragment
    %i[cisco_nxos h3c huawei].each do |vendor|
      prompt = vendor == :cisco_nxos ? "switch#" : "[switch]"
      deceptive = vendor == :cisco_nxos ? "description uplink#" : "description [uplink]"
      commands = Net::Connector.vendor_class(vendor).profile.config_commands
      script = <<~RUBY
        $stdout.sync = true
        print #{prompt.inspect}
        #{commands.inspect}.each_with_index do |command, index|
          abort unless $stdin.gets == command + "\n"
          if index == #{commands.size - 1}
            print "interface Ethernet1/1\n " + #{deceptive.inspect}
            sleep 0.05
            print "\ninterface Ethernet1/2\n description final-interface\n" + #{prompt.inspect}
          else
            print #{prompt.inspect}
          end
        end
        $stdin.read
      RUBY
      config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", command_timeout: 2)
      transport = LocalTransport.new(config, script)
      @device = Net::Connector.build(vendor, configuration: config, transport: transport)
      result = @device.running_config
      child = transport.channel
      pid = child.pid
      assert result.success?, "#{vendor}: #{result.error.inspect}"
      assert_includes result.config, "description final-interface", vendor.to_s
      @device.close
      refute child.alive?
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    end
  end
end
