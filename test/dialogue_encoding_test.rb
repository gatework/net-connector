# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"

class DialogueEncodingTest < Minitest::Test
  def test_diagnostic_uses_character_offsets_for_utf8_and_byte_offsets_for_binary
    ["中文说明\nError: invalid command\nrouter>",
     "中文 Error: 命令无效\nrouter>",
     "中文说明\nError: 命令无效"].zip(["Error: invalid command", "中文 Error: 命令无效", "Error: 命令无效"]).each do |input, expected|
      [input, input.b].each do |output|
        diagnostic = dialogue.diagnostic(output)
        assert_equal expected.b, diagnostic.b
        assert_equal output.encoding, diagnostic.encoding
        assert diagnostic.valid_encoding?
      end
    end
  end

  def test_colored_utf8_diagnostic_preserves_failure_before_redraw
    output = "中文说明\n\e[31mError:\e[0m 命令无效\rcleared\e[K\nrouter>"
    assert_equal "Error: 命令无效", dialogue.diagnostic(output)
  end

  def test_plain_and_crlf_diagnostics_leave_caller_output_unchanged
    ["\n", "\r\n", "\r"].each do |separator|
      output = ["中文说明", "Error: 命令无效", "router>"].join(separator).freeze
      original = output.dup
      diagnostic = dialogue.diagnostic(output)
      assert_equal "Error: 命令无效", diagnostic
      diagnostic.replace("changed")
      assert_equal original, output
    end
    assert_nil dialogue.diagnostic("ordinary output\nrouter>".freeze)
  end

  private

  def dialogue
    Net::Connector::Dialogue.new(login_prompt: />/, command_prompt: />/, password_prompt: /password:/,
                                username_prompt: /username:/, enable_prompt: /#/, authentication_errors: [],
                                command_errors: [/Error:/], login_interactions: [], command_interactions: [])
  end
end
