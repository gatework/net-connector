# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/remote_backup"

module Net
  module Connector
    module Vendor
      class Juniper < Net::Connector::Base
        # 操作视图直接导出已提交配置，不经过共享候选库，也不创建临时设备文件。
        class RemoteBackup
          def initialize(_device); end

          def script(target, password: nil)
            replies = if password.nil?
                        []
                      else
                        [Interaction.new(/(?:password(?: for [^\r\n:]*)?):\s*\z/i, "#{password}\n",
                                         sensitive: true, capture: false, limit: 1)]
                      end
            command = "show configuration | save #{target.url}"
            Script.new([Command.new(command, timeout: 180, interactions: replies, output_sensitive: true)])
          end

          # 只接受同一目标的完整写出行；进度、命令回显或提示符不是上传证据。
          def completed?(target, result)
            step = result.steps.last
            return false unless step

            output = Terminal::Renderer.render(step.output)
            return false if output.match?(/^[ \t]*(?:error:|(?:ftp|scp|ssh):\s|permission denied\b|lost connection\b)/i)

            output.each_line("\n").any? do |line|
              line.strip.match?(/\AWrote [1-9]\d* lines of output to '#{Regexp.escape(target.url)}'\z/)
            end
          end
        end
      end
    end
  end
end
