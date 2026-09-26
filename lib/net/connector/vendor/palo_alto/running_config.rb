# frozen_string_literal: true

require "shellwords"
require_relative "../../device/running_config/strategy"

module Net
  module Connector
    module PaloAlto
      class RunningConfig < Net::Connector::RunningConfig::Strategy
        def result_step(result)
          result.steps.find { |step| step.command.text == "show" }
        end

        # 采集切换视图时只改变结束符，仍绑定已认证的设备身份。
        def prompt_text(command)
          prompt = super
          case command.text
          when "configure" then prompt.sub(/[>#]\z/, "#")
          when "exit" then prompt.sub(/[>#]\z/, ">")
          else prompt
          end
        end

        def check_response(command, response, _execution)
          return unless command.text == "show config diff"
          return if body(response.output, command.text).empty?

          raise DeviceError.new("PAN-OS candidate differs from running configuration",
                                code: :uncommitted_configuration, host: @device.host, phase: :collect)
        end

        def clean(text)
          normalized = body(text, "show").sub(/(?:\A|\n)[ \t]*\[edit\][ \t]*\z/, "").strip
          unless set_commands?(normalized)
            raise DeviceError.new("PAN-OS configuration must be set format",
                                  code: :unsupported_configuration_format, host: @device.host, phase: :collect)
          end
          normalized
        end

        private

        # 证书等引号内换行必须闭合，不能将截断文本当成配置。
        def set_commands?(text)
          return false if text.empty?

          pending = +""
          text.each_line do |line|
            next if pending.empty? && line.strip.empty?
            return false if pending.empty? && !line.start_with?("set ")

            pending << line
            begin
              Shellwords.split(pending)
              pending.clear
            rescue ArgumentError
              # 未闭合引号继续读取；末尾仍未闭合则拒绝整个采集结果。
            end
          end
          pending.empty?
        end

        def body(text, command)
          text.gsub("\r\n", "\n").sub(/\A[ \t]*#{Regexp.escape(command)}[ \t]*\n/, "")
              .sub(@device.profile.command_prompt, "").strip
        end
      end
    end
  end
end
