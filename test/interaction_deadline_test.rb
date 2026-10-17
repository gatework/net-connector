# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "logger"
require "stringio"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class InteractionDeadlineTest < Minitest::Test
  Connector = Net::Connector

  def test_expired_command_confirmation_is_not_sent_and_later_commands_do_not_run
    [nil, /finished>\z/].each do |prompt|
      now = 10.0
      transport = ConnectorFake.new("router#", "Confirm:", "router#", "reconnected\nrouter#")
      interaction = Connector::Interaction.new(/Confirm:\z/, ->(_) { now = 11.0; "yes\n" })
      device = build(transport)
      Expect.stub(:monotonic, -> { now }) do
        command = Connector::Command.new("copy config", timeout: 1, prompt: prompt, interactions: [interaction])
        result = device.execute_script([command, "must not run"])
        assert_instance_of(prompt ? Connector::PromptError : Connector::CommandTimeout, result.error)
        assert_equal :command, result.error.phase
        assert_equal "Confirm:", result.error.output
        assert_empty result.steps
        assert_equal ["copy config\n"], transport.writes
        refute device.connected?
        assert_equal 1, transport.closes
        assert device.execute_command("show next").success?
        assert_equal ["copy config\n", "show next\n"], transport.writes
      end
    ensure
      device&.close
    end
  end

  def test_expired_login_challenge_does_not_send_or_log_the_returned_secret
    now = 10.0
    output = StringIO.new
    secret = "late-dynamic-token"
    interaction = Connector::Interaction.new(/Token:\z/, ->(_) { now = 11.0; "#{secret}\n" })
    transport = ConnectorFake.new("Token:")
    device = build(transport, challenges: [interaction], login_timeout: 1,
                              logger: Logger.new(output), log_level: :debug)
    Expect.stub(:monotonic, -> { now }) do
      error = assert_raises(Connector::LoginTimeout) { device.connect }
      assert_equal :login, error.phase
      assert_nil error.cause
      refute_includes error.full_message, secret
      refute_includes output.string, secret
      assert_empty transport.writes
      refute device.connected?
      assert_equal 1, transport.closes
    end
  ensure
    device&.close
  end

  def test_expired_enable_password_is_not_sent
    now = 10.0
    # 使用实际提示模式确定事件，不把认证模式索引作为测试契约。
    password_prompt = lambda do |patterns, _timeout|
      now = 11.0
      index = patterns.index { |pattern| pattern.match?("Password:") }
      Connector::Event.new(index: index, match: "Password:")
    end
    transport = ConnectorFake.new("router>", password_prompt)
    connector_class = Class.new(Connector::Base) do
      profile do
        prompts { login(/router>\z/); command(/router#\z/) }
        privilege { command "enable"; prompt(/router#\z/) }
      end
    end
    device = connector_class.new(host: "192.0.2.1", username: "operator", transport: transport,
                                 password: "enable-secret", login_timeout: 1)
    Expect.stub(:monotonic, -> { now }) do
      error = assert_raises(Connector::LoginTimeout) { device.enable }
      assert_equal :enable, error.phase
      assert_equal ["enable\n"], transport.writes
      refute device.connected?
    end
  ensure
    device&.close
  end

  def test_timely_confirmation_and_zero_timeout_initial_command_keep_their_contracts
    transport = ConnectorFake.new("router#", "Confirm:", "done\nrouter#", "zero\nrouter#")
    interaction = Connector::Interaction.new(/Confirm:\z/, "yes\n")
    device = build(transport)
    Expect.stub(:monotonic, 10.0) do
      assert device.execute_command("copy config", timeout: 1, interactions: [interaction]).success?
      assert device.execute_command("show cached", timeout: 0).success?
      assert_equal ["copy config\n", "yes\n", "show cached\n"], transport.writes
    end
  ensure
    device&.close
  end

  def test_callback_failure_keeps_priority_when_the_callback_also_exhausts_the_deadline
    now = 10.0
    interaction = Connector::Interaction.new(/Confirm:\z/, lambda { |_|
      now = 11.0
      raise Connector::ScriptError, "callback refused"
    })
    transport = ConnectorFake.new("router#", "Confirm:")
    device = build(transport)
    Expect.stub(:monotonic, -> { now }) do
      result = device.execute_command("copy config", timeout: 1, interactions: [interaction])
      assert_instance_of Connector::ScriptError, result.error
      assert_equal "callback refused", result.error.message
      assert_equal ["copy config\n"], transport.writes
      refute device.connected?
    end
  ensure
    device&.close
  end

  private

  def build(transport, **settings)
    Connector.build(:cisco_ios, host: "192.0.2.1", username: "operator", transport: transport, **settings)
  end
end
