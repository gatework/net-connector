# frozen_string_literal: true

require_relative "../progress"

module Net
  module Connector
    module Collect
      # VXLAN 与无线采集共用的证据结果协议；状态与报告保存分别判断。
      class Progress < Net::Connector::Progress
        # 清单总量在筛选前统计；未选设备不进入执行阶段。
        def plan(devices:, total:, parallel:, label:)
          @skipped = total - devices.size
          super(total: total, selected: devices.size, parallel: parallel, label: label)
        end

        # 采集设备使用统一的公开身份字段，不传入凭据。
        def start(device)
          super(host: device.fetch("host"))
        end

        # 完整且已保存的证据才计为成功；正常设备默认不逐台刷屏。
        def result(result)
          status = result_status(result)
          code = diagnostic_code(result)
          message = case status
                    when "complete" then "Collection complete; reports saved"
                    when "partial" then "Partially complete (#{code})"
                    else "Incomplete (#{code})"
                    end
          super(host: result.fetch("device").fetch("host"), success: status == "complete",
                duration_ms: result.fetch("duration_ms"), message: message, error_code: code&.to_sym)
        end

        # 使用持久化摘要作最终判定，不把已处理数量或完整性当作健康结论。
        def finish(summary)
          results = summary.fetch("devices")
          counts = results.group_by { |result| result_status(result) }.transform_values(&:size)
          failures = results.reject { |result| result_status(result) == "complete" }
                            .group_by { |result| diagnostic_code(result) }.transform_values(&:size)
          super(success: summary.fetch("status") == "complete", succeeded: counts.fetch("complete", 0),
                partial: counts.fetch("partial", 0), failed: counts.fetch("failed", 0), skipped: @skipped || 0, failures: failures)
          pending = summary.fetch("pending").size
          notice("Not collected: #{pending} devices; see the batch report") if pending.positive?
          notice("Complete evidence does not establish network health; see the review results in the report.")
          location(File.join(summary.fetch("directory"), "summary.json"))
          location(File.join(summary.fetch("directory"), "summary.txt"), label: "Text report")
        end

        private

        # 写入失败的完整快照仍是未交付结果，不能在终端宣称成功。
        def result_status(result)
          return "failed" unless result["report_saved"] == true

          %w[complete partial].include?(result["status"]) ? result["status"] : "failed"
        end

        # 完整维度的提示不属于失败；优先保留会话错误，再选择未完成维度的诊断码。
        def diagnostic_code(result)
          return "report_not_saved" unless result["report_saved"] == true
          return nil if result["status"] == "complete"
          return result["error"] if result["error"]

          dimensions = result.fetch("dimensions", {}).values.reject { |dimension| dimension["status"] == "complete" }
          dimensions.flat_map { |dimension| dimension.fetch("issues", []) }.first || "collection_incomplete"
        end
      end
    end
  end
end
