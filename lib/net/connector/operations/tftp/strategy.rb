# frozen_string_literal: true

module Net
  module Connector
    module Operations
      module Tftp
        autoload :H3c, File.expand_path("h3c", __dir__)
        autoload :CiscoIos, File.expand_path("cisco_ios", __dir__)
        autoload :CiscoNxos, File.expand_path("cisco_nxos", __dir__)
        autoload :Huawei, File.expand_path("huawei", __dir__)
        autoload :Hillstone, File.expand_path("hillstone", __dir__)
        autoload :Radware, File.expand_path("radware", __dir__)
        autoload :PaloAlto, File.expand_path("palo_alto", __dir__)

        class Strategy
          # 保存 TFTP 厂商策略使用的设备对象。
          def initialize(device)
            @device = device
            @responses = []
          end

          # 返回调用方指定的配置源文件。
          def source_file(value) = value

          # 根据设备地址生成默认远端文件名。
          def default_path(_source_file) = TftpTarget.filename(@device.host, extension: "cfg")

          # 返回目标中指定的远端文件名。
          def remote_path(target, _result) = target.path

          private

          # 记录脚本的静态响应，避免文件名或 VRF 回显成为传输完成证据。
          def interaction(pattern, response)
            @responses << response.chomp
            Interaction.new(pattern, response, capture: false)
          end

          # 只从设备消息中核对完成状态；命令、交互响应和最终提示均不是传输证据。
          def completion_lines(result)
            step = result.steps.last
            return [] unless step

            output = TerminalRenderer.render(step.output)
            prompt = TerminalRenderer.render(step.prompt.to_s)
            output = output.delete_suffix(prompt) unless prompt.empty?
            echoes = [step.command.text, "#{prompt.strip}#{step.command.text}", *@responses]
            output.each_line.map(&:strip).reject { |line| line.empty? || echoes.include?(line) }
          end

          # 只接受字节数非零、已发送量与总量相同的 curl 完成进度行。
          def completed_progress?(line)
            line.match?(/\A100\s+([1-9]\d*(?:\.\d+)?[kMGT]?)\s+0\s+0\s+100\s+\1(?:\s+[\d.:kMGT-]+)*\z/i)
          end

          # H3C 和华为的上传完成消息使用相同的文本及进度格式。
          def completed_upload?(line)
            line.match?(/\A
              (?:File\s+)?(?:transfer|upload)(?:\s+(?:is|was))?\s+
              (?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?(?:\s+successfully)?)[.!]?
              \z/ix) ||
              line.match?(/\A[1-9]\d*\s+bytes?\s+sent(?:\s+in\s+[\d.]+\s+(?:secs?|seconds?))?[.!]?\z/i) ||
              completed_progress?(line)
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
end
