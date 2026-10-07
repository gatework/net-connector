# frozen_string_literal: true

require_relative "../../storage/private_file"
require_relative "../report"

module Net
  module Connector
    module Netdisco
      class Report
        # 将批次结果写为人类可读的文本摘要。
        class Text
          def self.write(directory:, report:, plan:, concurrency:)
            summary = report.statistics
            failed = report.outcomes.reject { |item| item.success? || %i[filtered sample_limit].include?(item.status) }
            groups = failed.group_by { |item| item.error_code || item.status }
            lines = ["网络设备备份报告", "=" * 72,
                     "开始时间：#{report.started_at.getlocal("+08:00").strftime("%Y-%m-%d %H:%M:%S %:z")}",
                     "结束时间：#{report.finished_at.getlocal("+08:00").strftime("%Y-%m-%d %H:%M:%S %:z")}",
                     "清单：#{plan.inventory.size} 台；本次：#{plan.ready.size} 台；并发：#{concurrency}",
                     "成功：#{summary[:succeeded]}；部分成功：#{summary[:partial]}；失败：#{summary[:failed]}；跳过：#{summary[:skipped]}",
                     "耗时：#{(report.duration_ms.to_f / 1000).round(1)} 秒；批次状态：#{summary[:status]}",
                     "成功策略：#{report.policy}；策略通过：#{report.policy_success?}",
                     "回调异常：#{report.callback_errors.size}；报告错误：#{report.report_error || "无"}",
                     "状态计数：#{report.counts.map { |key, value| "#{key}=#{value}" }.join("，")}",
                     "未完成分类：#{groups.empty? ? "无" : groups.map { |key, items| "#{key}=#{items.size}" }.join("，")}",
                     "-" * 72, "未完成设备："]
            lines.concat(failure_lines(failed))
            lines << "无" if failed.empty?
            lines << "TFTP 成功仅表示设备报告上传完成；服务器文件核验结果请查看 summary.json。" if report.mode == :tftp
            lines += ["=" * 72, "备份目录：#{directory}", "完整明细：#{File.join(directory, "summary.json")}"]
            Net::Connector::Storage::PrivateFile.write(File.join(directory, "summary.txt"), lines.join("\n") + "\n")
          end

          def self.failure_lines(failed)
            failed.map do |item|
              label = item.device.name.to_s.gsub(/[[:cntrl:]]/, " ")
              "#{item.device.host} | #{label} | #{item.status} | #{item.error_code || "无错误码"} | #{item.duration_ms} ms"
            end
          end
          private_class_method :failure_lines
        end
      end
    end
  end
end
