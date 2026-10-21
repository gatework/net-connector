# frozen_string_literal: true

require_relative "interaction"
require_relative "terminal/renderer"

module Net
  module Connector
    # 每台设备一份不可变对话语法，由厂商方法组装而不是合并默认值。
    class Dialogue
      # 只读提供各阶段提示符、错误回显和允许的交互规则。
      attr_reader :login_prompt, :command_prompt, :password_prompt, :username_prompt, :enable_prompt,
                  :authentication_errors, :command_errors, :login_interactions, :command_interactions

      # 校验提示和交互列表，并冻结整套设备对话语法。
      def initialize(login_prompt:, command_prompt:, password_prompt:, username_prompt:, enable_prompt:,
                     authentication_errors:, command_errors:, login_interactions:, command_interactions:)
        @login_prompt = login_prompt
        @command_prompt = command_prompt
        @password_prompt = password_prompt
        @username_prompt = username_prompt
        @enable_prompt = enable_prompt
        [login_prompt, command_prompt, password_prompt, username_prompt, enable_prompt].each do |pattern|
          raise ArgumentError, "prompt must be a nonempty Regexp" unless pattern.is_a?(Regexp) && !pattern.match?("")
        end
        @authentication_errors = patterns(authentication_errors, :authentication_errors)
        @command_errors = patterns(command_errors, :command_errors)
        @login_interactions = interactions(login_interactions, :login_interactions)
        @command_interactions = interactions(command_interactions, :command_interactions)
        freeze
      end

      # 从命令输出中返回包含错误模式的诊断行，而不是光标或此前全部输出。
      def diagnostic(output)
        return if command_errors.empty?

        # 样式不改变诊断历史；先拼回被颜色拆开的词，再保留重绘之前的失败。
        raw = output
        raw = raw.gsub(/\e\[[0-9;:]*m/, "") if raw.include?("\e")
        raw = raw.gsub(/\r(?!\n)/, "\n") if raw.include?("\r")
        diagnostic_line(raw) || (diagnostic_line(Terminal::Renderer.render(output)) if output.match?(/[\e\b]/))
      end

      private

      # 自定义对话遵循与 Profile 相同的非空匹配规则，不冻结调用方数组。
      def patterns(values, name)
        unless values.is_a?(Array) && values.all? { |value| value.is_a?(Regexp) && !value.match?("") }
          raise ArgumentError, "#{name} must be an Array of nonempty Regexp objects"
        end

        values.map { |value| value.frozen? ? value : value.dup.freeze }.freeze
      end

      # 交互对象自身不可变，只复制所属列表。
      def interactions(values, name)
        unless values.is_a?(Array) && values.all?(Interaction)
          raise ArgumentError, "#{name} must be an Array of Interaction objects"
        end

        values.dup.freeze
      end

      # 只截取命中错误模式的当前行，避免把整段设备配置写进诊断信息。
      def diagnostic_line(output)
        match = command_errors.lazy.filter_map { |pattern| pattern.match(output) }.first
        return unless match

        start = match.begin(0).positive? ? output.rindex(/[\r\n]/, match.begin(0) - 1) : nil
        start = start ? start + 1 : 0
        finish = output.index(/[\r\n]/, match.end(0)) || output.length
        output[start...finish].strip
      end
    end

  end
end
