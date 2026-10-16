# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class DialogueContractTest < Minitest::Test
  Connector = Net::Connector

  def test_rule_collections_are_snapshots_without_freezing_caller_arrays
    interaction = Connector::Interaction.new(/Continue:/, "yes\n")
    fields = { authentication_errors: [/denied/], command_errors: [/Error:/],
               login_interactions: [interaction], command_interactions: [interaction] }
    original = fields.transform_values(&:dup)
    value = dialogue(**fields)
    fields.each do |name, values|
      refute_predicate values, :frozen?
      values.clear
      assert_equal original.fetch(name), value.public_send(name)
      assert_predicate value.public_send(name), :frozen?
    end
    assert_equal "Error: invalid", value.diagnostic("Error: invalid\nrouter#")
  end

  def test_invalid_error_patterns_fail_at_construction
    %i[authentication_errors command_errors].each do |name|
      [nil, /Error:/, ["Error:"], [//], [/x*/]].each do |value|
        assert_raises(ArgumentError, name.to_s) { dialogue(**{ name => value }) }
      end
    end
  end

  def test_invalid_interactions_fail_at_construction
    %i[login_interactions command_interactions].each do |name|
      [nil, {}, [Object.new]].each do |value|
        assert_raises(ArgumentError, name.to_s) { dialogue(**{ name => value }) }
      end
    end
  end

  def test_invalid_later_field_does_not_freeze_earlier_caller_arrays
    patterns = [/denied/]
    assert_raises(ArgumentError) { dialogue(authentication_errors: patterns, command_interactions: [nil]) }
    refute_predicate patterns, :frozen?
  end

  private

  def dialogue(**fields)
    Connector::Dialogue.new(**{ login_prompt: />/, command_prompt: />/, password_prompt: /password:/,
                               username_prompt: /username:/, enable_prompt: /#/, authentication_errors: [],
                               command_errors: [], login_interactions: [], command_interactions: [] }.merge(fields))
  end
end
