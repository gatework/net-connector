# frozen_string_literal: true

require "expect/pty"
require_relative "dialogue"

module Net
  module Connector
    # 在传输层上执行有界对话；收到字节或分页标记不会重置截止时间。
    class ResponseReader
      # 保存会话引用，以便读取器使用传输、配置和脱敏上下文。
      def initialize(session)
        @session = session
      end

      # 读取到结束提示、失败模式或超时，并处理交互响应和输出上限。
      def read(prompt:, interactions:, phase:, timeout: nil, deadline: nil, command: nil, failures: {})
        deadline ||= Expect.monotonic + timeout
        patterns = [*failures.keys, *interactions.map(&:pattern), prompt]
        raw = []
        output = []
        counts = Hash.new(0)
        bytes = 0
        loop do
          event = read_event(patterns, deadline)
          raw << event.before unless event.before.empty?
          output << event.before unless event.before.empty?
          bytes += event.before.bytesize + event.match.bytesize
          validate_event!(event, bytes, raw, phase, command)

          if event.index == patterns.size
            raw << event.match
            output << event.match
          elsif event.index == patterns.size - 1
            return finish_response(event.match, raw, output, phase, command)
          elsif event.index < failures.size
            raise build_connection_error(failures.values.fetch(event.index), phase, command), cause: nil
          else
            reply = interactions.fetch(event.index - failures.size)
            raw << event.match
            output << event.match if reply.capture?
            respond(reply, event.match, counts, deadline, phase, command)
          end
          next if Expect.monotonic < deadline

          raise build_read_error(nil, phase, command, raw.join), cause: nil
        end
      end

      private

      # 分页和流式输出只消耗剩余时间，不为下一次读取重新计时。
      def read_event(patterns, deadline)
        @session.transport.read(patterns, timeout: [deadline - Expect.monotonic, 0].max)
      end

      # 连接失败模式携带稳定错误码，供连接级恢复规则选择处理方式。
      def build_connection_error(failure, phase, command)
        klass, code = failure
        @session.build_error(klass, "device connection failed (#{code})", phase: phase, code: code, command: command)
      end

      # 先限制原始字节数，再处理传输失败，避免错误输出绕过总量限制。
      def validate_event!(event, bytes, raw, phase, command)
        if bytes > @session.configuration.max_output_bytes
          raise @session.build_error(OutputLimitExceeded, "device output exceeded max_output_bytes",
                                     phase: phase, command: command, output: (raw + [event.match]).join), cause: nil
        end
        raise build_read_error(event, phase, command, raw.join), cause: nil unless event.matched?
      end

      # 完整提示符必须消费字节；交互标记可从业务输出排除，但原始响应始终保留。
      def finish_response(prompt, raw, output, phase, command)
        if prompt.empty?
          raise @session.build_error(PromptError, "prompt pattern did not consume any output",
                                     phase: phase, command: command, output: raw.join), cause: nil
        end

        raw << prompt
        output << prompt
        raw_text = raw.join
        Response.new(raw: raw_text, output: (output == raw) ? raw_text : output.join, prompt: prompt)
      end

      # 重复提示和缺失应答必须在写入前失败；所有应答共用读取操作的截止时间。
      def respond(reply, prompt, counts, deadline, phase, command)
        counts[reply] += 1
        if prompt.empty? || (reply.limit && counts[reply] > reply.limit)
          raise build_interaction_error("response rejected or repeated", phase, command), cause: nil
        end

        value = interaction_response(reply, prompt, phase, command)
        raise build_interaction_error("response unavailable", phase, command), cause: nil unless value.is_a?(String)

        @session.redactor.remember(value.chomp) if reply.sensitive?
        @session.write(value, deadline: deadline, phase: phase, command: command)
      end

      # 动态口令尚未返回时无法加入词表，须在敏感范围内先归一化回调异常。
      # 成功后由调用方登记响应，临时敏感标记不会影响后续普通命令的诊断。
      def interaction_response(reply, prompt, phase, command)
        return reply.response(prompt) unless reply.sensitive?

        @session.redactor.with_scope(reuse: true) do
          @session.redactor.sensitive!
          reply.response(prompt)
        rescue => error
          raise @session.normalize_error(error, phase: phase, command: command), cause: nil
        end
      end

      # 将交互拒绝或响应缺失转换为认证或脚本错误。
      def build_interaction_error(message, phase, command)
        authenticating = %i[login enable].include?(phase)
        klass = authenticating ? AuthenticationError : ScriptError
        label = authenticating ? "authentication" : "command interaction"
        @session.build_error(klass, "#{label} #{message}", phase: phase, command: command)
      end

      # 根据 EOF、提示符、阶段和底层异常选择具体读取错误类型。
      def build_read_error(event, phase, command, output)
        if event&.error.is_a?(Exception)
          return @session.build_error(TransportError, "transport read failed", phase: phase, command: command,
                                      underlying: event.error, output: output)
        end
        klass = if event&.error == :eof
                  ConnectionClosed
                elsif command&.prompt
                  PromptError
                elsif %i[login enable].include?(phase)
                  LoginTimeout
                else
                  CommandTimeout
                end
        @session.build_error(klass, "device response #{event&.error || :timeout}", phase: phase,
                             command: command, output: output)
      end
    end
  end
end
