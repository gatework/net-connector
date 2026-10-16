# frozen_string_literal: true

require_relative "errors"
require_relative "command"

module Net
  module Connector
    # 一条已完成命令的结果；后续命令失败时仍保留已完成步骤。
    class CommandResult
      attr_reader :command, :output, :prompt, :duration

      # 保存命令输出、提示符和耗时，并冻结结果。
      def initialize(command:, output:, prompt:, duration:)
        raise ArgumentError, "command must be a Command" unless command.is_a?(Command)
        raise ArgumentError, "output must be a String" unless output.is_a?(String)
        raise ArgumentError, "prompt must be a String or nil" unless prompt.nil? || prompt.is_a?(String)
        unless duration.is_a?(Numeric) && duration.real? && duration.finite? && duration >= 0
          raise ArgumentError, "duration must be a finite nonnegative real number"
        end

        @command = command
        @output = output.frozen? ? output : output.dup.freeze
        @prompt = prompt&.dup&.freeze
        @duration = duration
        freeze
      end

      # 返回输出字节数和耗时摘要。
      def inspect = "#<#{self.class} bytes=#{output.bytesize} duration=#{duration.round(6)}>"
    end

    # 不可变执行结果；构造结果不会复制已经累计的命令输出前缀。
    class Result
      include Enumerable

      attr_reader :steps, :error, :config

      # 校验步骤、错误和配置文本，并冻结结果容器。
      def initialize(steps: [], error: nil, config: nil)
        raise ArgumentError, "error must be a Connector::Error or nil" unless error.nil? || error.is_a?(Error)
        unless steps.is_a?(Array) && steps.all?(CommandResult)
          raise ArgumentError, "steps must be an Array of CommandResult objects"
        end
        raise ArgumentError, "config must be a String or nil" unless config.nil? || config.is_a?(String)

        @steps = steps.dup.freeze
        @error = error
        @config = config&.dup&.freeze
        freeze
      end

      # 判断执行是否成功。
      def success? = error.nil?

      # 判断执行是否失败。
      def failure? = !success?

      # 遍历已完成命令步骤。
      def each(&) = steps.each(&)

      # 拼接所有已完成步骤的输出字节。
      def output
        return steps.first.output.b if steps.size == 1

        # 拼接前统一编码；仅在拼接后调用 b 无法避免不同编码之间的冲突。
        steps.map do |step|
          step.output.encoding == Encoding::BINARY ? step.output : step.output.b
        end.join("").force_encoding(Encoding::BINARY)
      end

      # 成功时返回配置或输出，失败时重新抛出领域错误。
      def value!
        raise error, cause: nil if failure?

        config || output
      end

      # 返回结果成功状态、步骤数量和错误码摘要。
      def inspect = "#<#{self.class} success=#{success?} steps=#{steps.size} code=#{error&.code.inspect}>"
    end
  end
end
