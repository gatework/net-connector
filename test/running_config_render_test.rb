# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class RunningConfigRenderTest < Minitest::Test
  def teardown = @device&.close

  def test_rendered_collection_reuses_the_large_response_for_presence_validation
    body = "interface Ethernet1/1\n description uplink\n!\n" * 1024
    response = "show running-config\n#{body}Switch#"
    transport = ConnectorFake.new("Switch#", "Switch#", response)
    @device = Net::Connector.build(:centec, host: "192.0.2.1", username: "reader", transport: transport)
    renderer = Net::Connector::Terminal::Renderer
    render = renderer.method(:render)
    large_inputs = []
    renderer.stub(:render, lambda { |text, **options|
      large_inputs << text.bytesize if text.bytesize > 1024
      render.call(text, **options)
    }) do
      result = @device.running_config
      assert result.success?, result.error.inspect
      assert_equal body, result.config
    end
    assert_equal [response.bytesize], large_inputs
  end

  def test_custom_mutating_cleaner_does_not_rewrite_the_presence_evidence
    strategy = Class.new(Net::Connector::RunningConfig::Rendered) do
      def clean(text) = super.replace("invented configuration")
    end
    connector = Class.new(Net::Connector::Base)
    connector.profile do
      running_config_strategy strategy
      commands { running_config "show config" }
      prompts { login(/device#\z/); command(/device#\z/) }
    end
    @device = connector.new(host: "192.0.2.1", username: "reader",
                            transport: ConnectorFake.new("device#", "show config\ndevice#"))
    result = @device.running_config
    assert_equal :incomplete_configuration, result.error&.code
    assert_nil result.config
  end

  def test_offline_cleaning_keeps_mutable_inputs_and_return_values_independent
    strategy = Net::Connector::RunningConfig::Rendered.new(nil)
    source = +"hostname first"
    strategy.clean(source).replace("changed by caller")
    assert_equal "hostname first", strategy.clean(source)
    source.replace("hostname second")
    assert_equal "hostname second", strategy.clean(source)
  end

  def test_prompt_redrawing_the_current_line_keeps_the_original_presence_boundary
    strategy = Class.new(Net::Connector::RunningConfig::Rendered)
    connector = Class.new(Net::Connector::Base)
    connector.profile do
      running_config_strategy strategy
      commands { running_config "show config" }
      prompts { login(/device#\z/); command(/device#\z/) }
    end
    # The matched prompt includes the carriage return; only its raw suffix is excluded.
    @device = connector.new(host: "192.0.2.1", username: "reader",
                            transport: ConnectorFake.new("device#", "hostname router\rdevice#"))
    @device.define_singleton_method(:config_commands) do
      [Net::Connector::Command.new("show config", prompt: /\rdevice#\z/)]
    end
    result = @device.running_config
    assert result.success?, result.error.inspect
    assert_equal "device#e router", result.config
  end
end
