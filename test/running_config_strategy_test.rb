# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class RunningConfigStrategyTest < Minitest::Test
  def teardown = @device&.close

  def test_custom_collection_strategy_controls_selection_and_cleaning_inside_the_session
    strategy = Class.new(Net::Connector::Operations::RunningConfig::Strategy) do
      def result_step(result) = result.steps.first
      def clean(text) = text.sub(/\nswitch#\z/, "").upcase

      def check_response(_command, _response, _execution)
        result = @device.execute("interleaved")
        raise "collection response hook was outside the session lock" unless result.error.is_a?(Net::Connector::SessionBusy)
      end
    end
    parent = Net::Connector.vendor_class(:cisco_ios)
    klass = Class.new(parent)
    klass.profile do
      commands { running_config "collect", "verify" }
      running_config_strategy strategy
    end
    inherited = Class.new(klass)
    transport = ConnectorFake.new("switch#", "hostname switch\nswitch#", "verified\nswitch#")
    @device = inherited.new(host: "192.0.2.1", username: "audit", transport: transport)
    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_equal "HOSTNAME SWITCH", result.config
    assert_equal ["collect\n", "verify\n"], transport.writes
    assert_same strategy, inherited.profile.running_config_strategy
    refute_same strategy, parent.profile.running_config_strategy
    assert_equal klass.profile.to_h, Net::Connector::Profile.new(**klass.profile.to_h).to_h
  end

  def test_panos_diff_guard_is_scoped_to_collection
    transport = ConnectorFake.new("admin@fw>", "show config diff\n+ changed value\nadmin@fw>")
    @device = Net::Connector.build(:palo_alto, host: "192.0.2.1", username: "audit", transport: transport)
    result = @device.execute("show config diff")
    assert result.success?, result.error.inspect
    assert_includes result.output, "+ changed value"
  end

  def test_response_state_reaches_inherited_selection_and_cleaning_hooks_and_expires_between_calls
    instances = []
    strategy = stateful_strategy(instances)
    klass = Class.new(Net::Connector.vendor_class(:cisco_ios)) do
      attr_reader :offline_config, :selected_command

      def clean_config(text)
        # 另一个 Fiber 的离线清理不能借用当前采集的临时状态。
        @offline_config = Fiber.new { super("offline") }.resume
        "wrapped:#{super}"
      end

      protected

      def config_result_step(result)
        step = super
        @selected_command = step.command.text
        step
      end
    end
    klass.profile do
      commands { running_config "primary", "secondary", "verify" }
      running_config_strategy strategy
    end
    transport = ConnectorFake.new("switch#", "first\nswitch#", "unused\nswitch#", "select primary\nswitch#",
                                  "unused\nswitch#", "second\nswitch#", "select secondary\nswitch#")
    @device = Class.new(klass).new(host: "192.0.2.1", username: "audit", transport: transport)

    first = @device.running_config
    second = @device.collect_config
    assert first.success?, first.error.inspect
    assert second.success?, second.error.inspect
    assert_equal "wrapped:3:first", first.config
    assert_equal "wrapped:3:second", second.config
    assert_equal "fresh:offline", @device.offline_config
    assert_equal "secondary", @device.selected_command
    assert_equal [3, 0, 3, 0], instances.map(&:responses)
    assert_equal %w[primary secondary verify primary secondary verify], transport.writes.map(&:strip)
  end

  def test_failed_cleaning_releases_strategy_state_and_retains_completed_steps
    instances = []
    strategy = Class.new(stateful_strategy(instances)) do
      def clean(text)
        raise Net::Connector::DeviceError, "rejected configuration" if text.start_with?("rejected")

        super
      end
    end
    klass = Class.new(Net::Connector.vendor_class(:cisco_ios))
    klass.profile do
      commands { running_config "primary", "verify" }
      running_config_strategy strategy
    end
    transport = ConnectorFake.new("switch#", "rejected\nswitch#", "select primary\nswitch#",
                                  "switch#", "accepted\nswitch#", "select primary\nswitch#")
    @device = klass.new(host: "192.0.2.1", username: "audit", transport: transport)

    failed = @device.running_config
    assert_instance_of Net::Connector::DeviceError, failed.error
    assert_equal %w[primary verify], (failed.steps.map { |step| step.command.text })
    assert transport.closed?
    assert_equal "fresh:offline", @device.clean_config("offline")

    retried = @device.running_config
    assert retried.success?, retried.error.inspect
    assert_equal "2:accepted", retried.config
    assert_equal [2, 0, 2], instances.map(&:responses)
    assert_equal 2, transport.opens
  end

  def test_busy_collection_does_not_replace_the_active_strategy
    instances = []
    strategy = stateful_strategy(instances)
    klass = Class.new(Net::Connector.vendor_class(:cisco_ios)) do
      attr_reader :nested_result

      def clean_config(text)
        @nested_result = running_config
        super
      end
    end
    klass.profile do
      commands { running_config "primary", "verify" }
      running_config_strategy strategy
    end
    transport = ConnectorFake.new("switch#", "accepted\nswitch#", "select primary\nswitch#")
    @device = klass.new(host: "192.0.2.1", username: "audit", transport: transport)

    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_equal "2:accepted", result.config
    assert_instance_of Net::Connector::SessionBusy, @device.nested_result.error
    assert_equal %w[primary verify], transport.writes.map(&:strip)
    assert_equal [2, 0], instances.map(&:responses)
  end

  def test_huawei_tftp_does_not_change_privilege_but_later_collection_does
    transport = ConnectorFake.new("<Huawei>", "Transfer complete\n<Huawei>",
                                  "privilege level is 3\n<Huawei>", "sysname Huawei\n<Huawei>")
    @device = Net::Connector.build(:huawei, host: "192.0.2.1", username: "audit", transport: transport)
    @device.tftp_backup(host: "192.0.2.2", path: "backup.cfg", source_file: "startup.cfg")
    refute_includes transport.writes, "su\n"
    assert @device.running_config.success?
    assert_equal ["tftp 192.0.2.2 put startup.cfg backup.cfg\n", "su\n", "dis cur\n"], transport.writes
  end

  private

  def stateful_strategy(instances)
    Class.new(Net::Connector::Operations::RunningConfig::Strategy) do
      attr_reader :responses

      define_method(:initialize) do |device|
        super(device)
        @responses = 0
        instances << self
      end

      def check_response(command, response, _execution)
        @responses += 1
        @selected = response.output[/select (\w+)/, 1] if command.text == "verify"
      end

      def result_step(result)
        raise "selection lost the response state" unless @selected

        result.steps.find { |step| step.command.text == @selected }
      end

      def clean(text)
        return "fresh:#{text}" unless @selected

        "#{@responses}:#{text.sub(/\nswitch#\z/, "")}"
      end
    end
  end
end
