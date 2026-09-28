# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class ProfileContractTest < Minitest::Test
  Profile = Net::Connector::Profile

  def test_interaction_hooks_extend_profile_rules_through_super
    connector_class = Class.new(Net::Connector::Base) do
      profile do
        prompts { login(/router#\z/); command(/router#\z/) }
        interactions { login(/Accept:/, response: "yes\n"); confirm(/Confirm:/, response: "y\n") }
      end

      protected

      def login_interactions
        [*super, Net::Connector::Interaction.new(/Continue:/, "continue\n")]
      end

      def confirmation_interactions
        [*super, Net::Connector::Interaction.new(/Proceed:/, "proceed\n")]
      end
    end
    transport = ConnectorFake.new("Accept:", "Continue:", "router#", "Confirm:", "Proceed:", "done\nrouter#")
    device = connector_class.new(host: "192.0.2.1", username: "operator", transport: transport)
    result = device.execute_command("show status")
    assert result.success?, result.error.inspect
    assert_equal ["yes\n", "continue\n", "show status\n", "y\n", "proceed\n"], transport.writes
    assert_includes result.output, "done"
    %i[login_interactions confirmation_interactions].each do |hook|
      assert_includes connector_class.protected_instance_methods, hook
      refute device.respond_to?(hook)
    end
  ensure
    device&.close
  end

  def test_existing_dsl_inheritance_replaces_rules_and_appends_interactions
    parent = Profile.define do
      commands { running_config "prepare", "collect"; save_config "save" }
      prompts { login(/device>/); command(/device#/); username(/User:/); password(/Pass:/) }
      pager { pattern(/More:/); response " " }
      errors { authentication(/denied/); command(/invalid/) }
      interactions { login(/Accept:/, response: "yes\n"); confirm(/Confirm:/, response: "y\n") }
      privilege { command "enable"; prompt(/privileged#/) }
      ssh { legacy_arguments "-o", "Example=yes" }
      terminal_size 80, 24
      command_timeout 30
    end
    child = Profile.define(parent: parent) do
      commands { running_config "child collect" }
      errors { command(/child error/) }
      interactions { confirm(/Child:/, response: "ok\n") }
    end
    assert_equal ["prepare", "collect"], parent.config_commands
    assert_equal ["child collect"], child.config_commands
    assert_equal ["save"], child.save_commands
    assert_equal [/invalid/], parent.command_error_patterns
    assert_equal [/child error/], child.command_error_patterns
    assert_equal 1, parent.confirmation_interactions.size
    assert_equal 2, child.confirmation_interactions.size
    %i[login_prompt command_prompt username_prompt password_prompt pager_pattern pager_response
       authentication_error_patterns login_interactions privilege_command privilege_prompt
       legacy_ssh_arguments terminal_size command_timeout].each do |key|
      assert_equal parent.public_send(key), child.public_send(key), key.to_s
    end
    assert_equal child.to_h, Profile.new(**child.to_h).to_h
    assert parent.frozen?
    assert child.frozen?
    assert_raises(FrozenError) { child.config_commands.first << " changed" }
    assert_raises(FrozenError) { child.confirmation_interactions << nil }
  end

  def test_existing_invalid_declarations_fail_at_definition_time
    assert_raises(ArgumentError) { Profile.define { commands } }
    assert_raises(ArgumentError) { Profile.define { commands { running_config "bad\ncommand" } } }
    assert_raises(ArgumentError) { Profile.define { prompts { command(//) } } }
    assert_raises(ArgumentError) { Profile.define { terminal_size 0, 24 } }
  end

  def test_h3c_configuration_read_has_time_for_slow_devices_and_honors_explicit_timeout
    %i[h3c h3c_wireless].each do |vendor|
      [nil, 20].each do |configured|
        transport = ConnectorFake.new("<core>", ->(_patterns, timeout) {
          assert_operator timeout, :>, configured ? 19 : 59
          "sysname core\n<core>"
        })
        device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: transport,
                                      command_timeout: configured)
        begin
          assert device.running_config.success?
        ensure
          device.close
        end
      end
    end
  end
end
