# frozen_string_literal: true

require_relative "../../engine/command"
require_relative "target"
module Net
  module Connector
    class Tftp
      # 厂商声明命名、交互与完成证据；公共层统一过滤精确回显和保留失败历史。
      class Strategy
        # 声明默认配置扩展名，清单规划与设备直连共用同一命名规则。
        def self.file_extension = "cfg"

        # 不创建会话即可生成目标名，供批量计划检查文件覆盖风险。
        def self.filename(host, label: nil)
          TftpTarget.filename(host, extension: file_extension, label: label)
        end

        # 保存 TFTP 厂商策略使用的设备对象。
        def initialize(device) = @device = device

        # 返回调用方指定的配置源文件。
        def resolve_source_file(value) = value

        # 根据设备地址生成默认远端文件名。
        def default_path(_source_file) = self.class.filename(@device.host)

        # 返回目标中指定的远端文件名。
        def remote_path(target, _result) = target.path

        # 原文、历史和终端画面共同保存失败证据；仅过滤精确输入回显与提示符。
        def failure_outputs(result)
          return enum_for(__method__, result) unless block_given?

          result.steps.each do |step|
            yield evidence_lines(step, step.output).join("\n")
            yield evidence_lines(step, TerminalRenderer.render(step.output.gsub(/\r(?!\n)/, "\n"))).join("\n")
            yield evidence_lines(step, TerminalRenderer.render(step.output)).join("\n")
          end
        end

        private

        # 静态交互不进入业务输出，证据过滤从完成步骤读取原始声明。
        def interaction(pattern, response)
          Interaction.new(pattern, response, capture: false)
        end

        # 只从设备消息中核对完成状态；命令、交互响应和最终提示均不是传输证据。
        def completion_lines(result)
          step = result.steps.last
          return [] unless step

          output = TerminalRenderer.render(step.output)
          prompt = TerminalRenderer.render(step.prompt.to_s)
          output = output.delete_suffix(prompt) unless prompt.empty?
          evidence_lines(step, output)
        end

        # 移除精确命令、静态响应和提示符，保留回车重绘前后的设备消息。
        def evidence_lines(step, output)
          prompt = TerminalRenderer.render(step.prompt.to_s).strip
          responses = step.command.interactions.filter_map { |reply| reply.static_response&.chomp }
          echoes = [step.command.text, "#{prompt}#{step.command.text}", *responses]
          # 原文中的每次回车分开核对，避免重绘回显误报，也保留被覆盖的诊断。
          output.each_line.flat_map { |line| line.split(/\r(?!\n)/) }.map do |line|
            # 样式不改变字符历史；光标移动和擦除不能拿来删掉原始失败消息。
            line.gsub(/\e\[[0-9;:]*m/, "").strip
          end.reject { |line| line.empty? || line == prompt || echoes.include?(line) }
        end

        # 只接受字节数非零、已发送量与总量相同的 curl 完成进度行。
        def completed_progress?(line)
          line.match?(/\A100\s+([1-9]\d*(?:\.\d+)?[kMGT]?)\s+0\s+0\s+100\s+\1(?:\s+[\d.:kMGT-]+)*\z/i)
        end

        # Cisco 明确报告复制完成的字节数，可附带耗时和速率。
        def copied_bytes?(line)
          line.match?(/\A
            [1-9]\d*\s+bytes?\s+copied
            (?:\s+in\s+[\d.]+\s+(?:secs?|seconds?)(?:\s+\([\d.]+\s+bytes\/sec\))?)?[.!]?
            \z/ix)
        end
      end
    end
  end
end
