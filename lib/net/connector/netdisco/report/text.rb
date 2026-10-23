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
            lines = ["Network device backup report", "=" * 72,
                     "Started: #{report.started_at.getlocal("+08:00").strftime("%Y-%m-%d %H:%M:%S %:z")}",
                     "Finished: #{report.finished_at.getlocal("+08:00").strftime("%Y-%m-%d %H:%M:%S %:z")}",
                     "Inventory: #{plan.inventory.size} devices; selected: #{plan.ready.size} devices; concurrency: #{parallel}",
                     "Succeeded: #{summary[:succeeded]}; partial: #{summary[:partial]}; failed: #{summary[:failed]}; skipped: #{summary[:skipped]}",
                     "Elapsed: #{(report.duration_ms.to_f / 1000).round(1)} seconds; batch status: #{summary[:status]}",
                     "Success policy: #{report.policy}; policy passed: #{report.policy_success?}",
                     "Callback errors: #{report.callback_errors.size}; report error: #{summary[:report_error] || "none"}",
                     "Status counts: #{report.counts.map { |key, value| "#{key}=#{value}" }.join(", ")}",
                     "Incomplete categories: #{groups.empty? ? "none" : groups.map { |key, items| "#{key}=#{items.size}" }.join(", ")}",
                     "-" * 72, "Incomplete devices: "]
            lines.concat(failure_lines(failed))
            lines << "none" if failed.empty?
            if report.mode == :tftp
              verification = summary.fetch(:verification)
              lines << "TFTP server files: verified #{verification[:verified]}, unverified #{verification[:unverified]}."
            end
            lines += ["=" * 72, "Backup directory: #{directory}", "Full details: #{File.join(directory, "summary.json")}"]
            Net::Connector::Storage::AtomicFile.write(File.join(directory, "summary.txt"), lines.join("\n") + "\n")
          end

          # 格式化未完成设备列表，清除名称中的终端控制符。
          def self.failure_lines(failed)
            failed.map do |item|
              label = item.device.name.to_s.gsub(/[[:cntrl:]]/, " ")
              "#{item.device.host} | #{label} | #{item.status} | #{diagnostic_code(item) || "no error code"} | #{item.duration_ms} ms"
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
