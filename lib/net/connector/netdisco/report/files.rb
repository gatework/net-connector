# frozen_string_literal: true

require "json"
require_relative "text"

module Net
  module Connector
    module Netdisco
      class Report
        # 示例与批次入口共享唯一摘要结构；保存结果先于终端成功提示。
        class Files
          def self.write(report, directory:, plan:, concurrency:)
            destination = File.join(directory, "summary.json")
            finalized = report.with(report_location: destination)
            Text.write(directory: directory, report: finalized, plan: plan, concurrency: concurrency)
            Storage::PrivateFile.write(destination, JSON.pretty_generate(finalized.summary))
            finalized
          rescue StandardError => error
            location = if Storage::PrivateFile.receipt_error?(error) && error.receipt.committed? && error.receipt.path == destination
                         destination
                       end
            failed = report.with_report_error(error, location: location)
            begin
              saved = failed.with(report_location: destination)
              Storage::PrivateFile.write(destination, JSON.pretty_generate(saved.summary))
              failed = saved
            rescue StandardError
              # JSON 仍无法保存时，返回带有已知提交位置的失败报告。
            end
            begin
              Text.write(directory: directory, report: failed, plan: plan, concurrency: concurrency)
            rescue StandardError
              # 文本输出不能覆盖首次保存失败。
            end
            failed
          end
        end
      end
    end
  end
end
