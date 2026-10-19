# frozen_string_literal: true

require_relative "../command"

module Net
  module Connector
    class Command
      # 一条已完成命令的结果；后续命令失败时仍保留已完成步骤。
      class Result
        # 只读提供单条已完成命令的输出、提示符与耗时。
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

    end
  end
end
