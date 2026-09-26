# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class ProfileContractTest < Minitest::Test
  Profile = Net::Connector::Profile

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
end
