# frozen_string_literal: true

require_relative "errors"
require_relative "dialogue"
require "expect/pty"

module Net
  module Connector
    # 一条设备命令行，可附带独立截止时间和交互规则。
    class Command
      attr_reader :text, :timeout, :interactions, :prompt, :source, :line

      # 在任何输入输出前校验命令、提示、交互和敏感标记，并冻结命令。
      def initialize(text, timeout: nil, interactions: [], prompt: nil, sensitive: false, source: nil, line: nil)
        unless text.is_a?(String) && !text.strip.empty? && !text.match?(/[\r\n\x00]/)
          raise ScriptError.new("a command must contain exactly one nonempty CLI line", phase: :parse,
                                source: source, line: line)
        end
        unless interactions.is_a?(Array) && interactions.all?(Interaction)
          raise ArgumentError, "interactions must be an Array of Interaction objects"
        end
        valid_prompt = prompt.nil? || (prompt.is_a?(Regexp) && !prompt.match?(""))
        unless valid_prompt
          raise ArgumentError, "prompt must be a nonempty Regexp or nil"
        end
        raise ArgumentError, "sensitive must be true or false" unless [true, false].include?(sensitive)

        @text = text.dup.freeze
        @timeout = Expect.duration(timeout)
        @interactions = interactions.dup.freeze
        @prompt = prompt
        @sensitive = sensitive
        @source = source&.dup&.freeze
        @line = line
        freeze
      end

      # 判断命令文本是否需要脱敏。
      def sensitive? = @sensitive

      # 复制命令元数据，只替换命令文本。
      def with_text(text)
        self.class.new(text, timeout: timeout, interactions: interactions, prompt: prompt,
                       sensitive: sensitive?, source: source, line: line)
      end

      # 返回命令来源摘要，不展开命令内容。
      def inspect = "#<#{self.class} source=#{source.inspect} line=#{line.inspect}>"
    end

    # 在任何输入输出前解析，不执行脚本，也不改写设备命令中的行内注释。
    class Script
      include Enumerable

      attr_reader :name

      # 按行过滤空行和整行注释，再构造带来源信息的命令。
      def self.parse(text, name: nil)
        raise ArgumentError, "script must be a String" unless text.is_a?(String)

        commands = text.each_line.with_index(1).filter_map do |line, number|
          line = line.chomp
          next if line.strip.empty? || line.lstrip.start_with?("#")

          Command.new(line, source: name, line: number)
        end
        new(commands, name: name)
      end

      # 读取脚本文件；文件错误转换为带来源的脚本错误。
      def self.load(path)
        parse(File.binread(path), name: File.expand_path(path))
      rescue IOError, SystemCallError
        raise ScriptError.new("unable to read script", phase: :parse, source: path.to_s), cause: nil
      end

      # 校验并冻结命令数组，给非 Command 输入补充来源和行号。
      def initialize(commands, name: nil)
        raise ArgumentError, "commands must be an Array" unless commands.is_a?(Array)

        @name = name&.dup&.freeze
        @commands = commands.each_with_index.map do |command, index|
          command.is_a?(Command) ? command : Command.new(command, source: name, line: index + 1)
        end.freeze
        freeze
      end

      # 遍历脚本命令。
      def each(&) = @commands.each(&)

      # 判断脚本是否没有可执行命令。
      def empty? = @commands.empty?

      # 返回脚本命令数量。
      def size = @commands.size

      # 返回脚本名称和命令数量摘要。
      def inspect = "#<#{self.class} name=#{name.inspect} commands=#{size}>"
    end
  end
end
