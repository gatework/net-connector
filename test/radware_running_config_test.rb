# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class RadwareRunningConfigTest < Minitest::Test
  def setup
    @prompt = ">> Standalone ADC - Configuration#"
    @config = "/c/sys\r\n\tname adc\r\n#\r\n"
  end

  def teardown = @device&.close

  def build_device(*events)
    @transport = ConnectorFake.new(*events)
    @device = Net::Connector.build(:radware, host: "192.0.2.1", username: "admin", transport: @transport)
  end

  def test_dump_changes_menu_and_can_be_collected_again
    build_device(">> Standalone ADC - Main# ", "Display private keys? [y/n]: ",
                 "#{@config}#{@prompt} ", "#{@config}#{@prompt} ")
    2.times do
      result = @device.running_config
      assert result.success?, result.error.inspect
      assert_includes result.config, "/c/sys\n\tname adc\n#\n"
      assert_equal @prompt, @device.current_prompt.strip
    end
    assert_equal ["/cfg/dump\n", "n\n", "/cfg/dump\n"], @transport.writes
  end

  def test_dump_preserves_device_identity_and_does_not_stop_at_config_hash
    build_device(">> Standalone ADC - Main#", "#{@config}>> Another ADC - Configuration#",
                 "\r\n/c/l3\r\n#{@prompt}")
    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_includes result.config, "/c/l3"
    assert_equal @prompt, result.steps.last.prompt
  end

  def test_wrong_device_prompt_cannot_complete_dump
    build_device(">> Standalone ADC - Main#", "#{@config}>> Another ADC - Configuration#", :timeout)
    result = @device.running_config
    assert result.failure?
    assert_equal :command_timeout, result.error.code
    assert_nil result.config
  end

  def test_missing_completion_preserves_existing_backup
    build_device(">> Standalone ADC - Main#", @config, :timeout)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "backup.cfg")
      File.write(path, "previous configuration")
      assert_raises(Net::Connector::CommandTimeout) { @device.backup(path: path) }
      assert_equal "previous configuration", File.read(path)
    end
  end

  def test_dump_from_bare_menu_prompt
    build_device(">> Main#", "#{@config}>> Configuration#")
    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_equal ">> Configuration#", @device.current_prompt
  end

  def test_menu_prompts_wait_for_terminator_when_received_in_fragments
    profile = Net::Connector.vendor_class(:radware).profile
    [profile.login_prompt, profile.command_prompt].each do |pattern|
      [">> adc - Standalone ADC - Main#", ">> adc - Standalone ADC - Configuration#"].each do |prompt|
        (2...prompt.length).each { |length| refute_match pattern, prompt[0, length] }
        assert_match pattern, prompt
      end
    end
  end
end
