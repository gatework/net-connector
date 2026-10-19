# frozen_string_literal: true

require "json"
require_relative "text"

module Net
  module Connector
    module Netdisco
      class Report
        # 示例与批次入口共享唯一摘要结构；保存结果先于终端成功提示。
        class Files
          # 文本和 JSON 分别提交；失败时尝试保存诊断，并保留已提交的 JSON 位置。
          def self.write(report, directory:, plan:, parallel:)
            destination = File.join(directory, "summary.json")
            finalized = report.with(report_location: destination)
            Text.write(directory: directory, report: finalized, plan: plan, parallel: parallel)
            Storage::AtomicFile.write(destination, JSON.pretty_generate(finalized.summary))
            finalized
          rescue StandardError => error
            location = committed_location(error, destination) || report.report_location
            # 更新已有诊断时仍保留首次报告故障，以及之前已提交的报告位置。
            failed = report.report_error ? report.with(report_location: location) : report.with_report_error(error, location: location)
            begin
              saved = failed.with(report_location: destination)
              Storage::AtomicFile.write(destination, JSON.pretty_generate(saved.summary))
              failed = saved
            rescue StandardError => persistence_error
              # 补写也可能在替换后失败；保留位置，但不覆盖首次报告故障。
              failed = saved if committed_location(persistence_error, destination)
            end
            begin
              Text.write(directory: directory, report: failed, plan: plan, parallel: parallel)
            rescue StandardError
              # 文本输出不能覆盖首次保存失败。
            end
            failed
          end

          # 仅从本库可信写入回执确认摘要文件已经提交的位置。
          def self.committed_location(error, destination)
            destination if Storage::AtomicFile.receipt_error?(error) && error.receipt.committed? && error.receipt.path == File.expand_path(destination)
          end
          private_class_method :committed_location
        end
      end
    end
  end
end
