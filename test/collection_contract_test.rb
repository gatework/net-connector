# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class CollectionContractTest < Minitest::Test
  def build_device(*events, &definition)
    klass = Class.new(Net::Connector::Base) do
      profile do
        commands { running_config "show config" }
        prompts do
          login(/device#\z/)
          command(/device#\z/)
        end
      end

      def clean_config(text) = text.sub(/device#\z/, "").strip
    end
    klass.class_eval(&definition) if definition
    @transport = ConnectorFake.new(*events)
    @device = klass.new(host: "192.0.2.1", username: "admin", transport: @transport)
  end

  def teardown = @device&.close

  def assert_incomplete(result)
    assert result.failure?
    assert_instance_of Net::Connector::DeviceError, result.error
    assert_equal :incomplete_configuration, result.error.code
    assert_equal :collect, result.error.phase
    assert_nil result.config
  end

  def test_empty_collection_commands_fail_without_opening_transport
    build_device { define_method(:config_commands) { [] } }
    assert @device.execute_script([]).success?
    assert_incomplete @device.running_config
    assert_equal 0, @transport.opens
  end

  def test_skipped_collection_steps_fail_and_close_session
    build_device("device#") { define_method(:prepare_command) { |*| nil } }
    result = @device.running_config
    assert_incomplete result
    assert_empty result.steps
    assert_equal 1, @transport.closes
  end

  def test_blank_cleaned_configuration_fails_with_completed_evidence
    build_device("device#", " \r\n device#")
    result = @device.running_config
    assert_incomplete result
    assert_equal ["show config"], (result.steps.map { |step| step.command.text })
    assert_equal 1, @transport.closes
  end

  def test_custom_cleaner_returning_nil_is_incomplete_configuration
    build_device("device#", "hostname router\ndevice#")
    @device.define_singleton_method(:clean_config) { |_text| nil }
    result = @device.running_config
    assert_incomplete result
    assert_equal ["show config"], (result.steps.map { |step| step.command.text })
    assert_equal 1, @transport.closes
  end

  def test_default_selection_is_last_completed_step
    build_device("device#", "terminal ready\ndevice#", "hostname router\ndevice#") do
      define_method(:config_commands) { ["prepare", "show config", "skipped"] }
      define_method(:prepare_command) do |command, _execution|
        command unless command.text == "skipped"
      end
    end
    result = @device.running_config
    assert result.success?
    assert_equal "hostname router", result.config
    assert_equal ["prepare", "show config"], (result.steps.map { |step| step.command.text })
  end

  def palo_device(show_output = "set system host-name firewall")
    @transport = ConnectorFake.new("admin@fw>", "admin@fw>", "admin@fw>", "admin@fw>",
                                   "admin@fw#", "#{show_output}\n[edit]\nadmin@fw#", "admin@fw>", "admin@fw>")
    @device = Net::Connector.build(:palo_alto, host: "192.0.2.1", username: "admin", transport: @transport)
  end

  def test_palo_running_config_selects_show_and_retains_complete_sequence
    palo_device
    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_equal "set system host-name firewall", result.config
    assert_equal @device.config_commands, (result.steps.map { |step| step.command.text })
  end

  def test_palo_missing_show_step_is_explicit_failure
    palo_device
    @device.define_singleton_method(:config_commands) { ["show config diff"] }
    result = @device.running_config
    assert_incomplete result
    assert_equal 1, result.steps.size
    assert_equal 1, @transport.closes
  end

  def test_palo_cleaning_occurs_inside_session_lock
    palo_device
    @device.define_singleton_method(:clean_config) do |text|
      @nested_result = execute_command("interleaved")
      super(text)
    end
    result = @device.running_config
    assert result.success?, result.error.inspect
    nested = @device.instance_variable_get(:@nested_result)
    assert_instance_of Net::Connector::SessionBusy, nested.error
    refute_includes @transport.writes, "interleaved\n"
  end

  def test_palo_invalid_configuration_closes_session_and_retains_steps
    palo_device("system { host-name firewall; }")
    result = @device.running_config
    assert result.failure?
    assert_equal :unsupported_configuration_format, result.error.code
    assert_equal 7, result.steps.size
    assert_equal 1, @transport.closes
  end

  def test_prompt_or_command_echo_is_not_configuration_for_any_vendor
    %i[h3c h3c_wireless cisco_ios cisco_nxos radware huawei hillstone].each do |vendor|
      [false, true].each do |echo|
        device, transport = empty_config_device(vendor, echo: echo)
        result = device.running_config
        assert_incomplete result
        assert_equal device.config_commands, (result.steps.map { |step| step.command.text })
        assert transport.closed?
      ensure
        device&.close
      end
    end
  end

  def test_empty_config_response_preserves_existing_backup
    Dir.mktmpdir do |directory|
      path = File.join(directory, "router.cfg")
      File.write(path, "previous configuration")
      device, = empty_config_device(:cisco_ios, echo: true)
      error = assert_raises(Net::Connector::DeviceError) { device.backup(path: path) }
      assert_equal :incomplete_configuration, error.code
      assert_equal "previous configuration", File.read(path)
    ensure
      device&.close
    end
  end

  private

  def empty_config_device(vendor, echo:)
    klass = Net::Connector.vendor_class(vendor)
    prompt = case vendor
             when :h3c, :h3c_wireless, :huawei then "<device>"
             when :radware then ">> device"
             else "device#"
             end
    events = [prompt]
    events << "privilege level is 3\n#{prompt}" if vendor == :huawei
    klass.profile.config_commands.each do |command|
      events << (echo ? "#{command}\r\n#{prompt}" : prompt)
    end
    transport = ConnectorFake.new(*events)
    [klass.new(host: "192.0.2.1", username: "admin", transport: transport), transport]
  end
end
