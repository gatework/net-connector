# frozen_string_literal: true

require_relative "../../storage/atomic_file"
require_relative "../report"

module Net
  module Connector
    module Netdisco
      class Report
        # 将批次结果写为人类可读的文本摘要。
        class Text
          # 生成可读批次与失败分类摘要，并原子写入私有文本报告。
          def self.write(directory:, report:, plan:, parallel:)
            summary = report.statistics
            failed = report.outcomes.reject { |item| item.success? || %i[filtered sample_limit].include?(item.status) }
            groups = failed.group_by { |item| diagnostic_code(item) || item.status }
            lines = ["网络设备备份报告", "=" * 72,
                     "开始时间：#{report.started_at.getlocal("+08:00").strftime("%Y-%m-%d %H:%M:%S %:z")}",
                     "结束时间：#{report.finished_at.getlocal("+08:00").strftime("%Y-%m-%d %H:%M:%S %:z")}",
                     "清单：#{plan.inventory.size} 台；本次：#{plan.ready.size} 台；并发：#{parallel}",
                     "成功：#{summary[:succeeded]}；部分成功：#{summary[:partial]}；失败：#{summary[:failed]}；跳过：#{summary[:skipped]}",
                     "耗时：#{(report.duration_ms.to_f / 1000).round(1)} 秒；批次状态：#{summary[:status]}",
                     "成功策略：#{report.policy}；策略通过：#{report.policy_success?}",
                     "回调异常：#{report.callback_errors.size}；报告错误：#{summary[:report_error] || "无"}",
                     "状态计数：#{report.counts.map { |key, value| "#{key}=#{value}" }.join("，")}",
                     "未完成分类：#{groups.empty? ? "无" : groups.map { |key, items| "#{key}=#{items.size}" }.join("，")}",
                     "-" * 72, "未完成设备："]
            lines.concat(failure_lines(failed))
            lines << "无" if failed.empty?
            if report.mode == :tftp
              verification = summary.fetch(:verification)
              lines << "TFTP 服务器文件：已核验 #{verification[:verified]}，未核验 #{verification[:unverified]}。"
            end
            lines += ["=" * 72, "备份目录：#{directory}", "完整明细：#{File.join(directory, "summary.json")}"]
            Net::Connector::Storage::AtomicFile.write(File.join(directory, "summary.txt"), lines.join("\n") + "\n")
          end

          # 格式化未完成设备列表，清除名称中的终端控制符。
          def self.failure_lines(failed)
            failed.map do |item|
              label = item.device.name.to_s.gsub(/[[:cntrl:]]/, " ")
              "#{item.device.host} | #{label} | #{item.status} | #{diagnostic_code(item) || "无错误码"} | #{item.duration_ms} ms"
            end
          end
          private_class_method :failure_lines

          # 与 JSON 报告共用诊断白名单，不将领域错误码作为自由文本呈现。
          def self.diagnostic_code(outcome)
            (outcome.diagnostic || Diagnostic.new(error_code: outcome.error_code)).error_code
          end
          private_class_method :diagnostic_code
        end
      end
    end
  end
end
