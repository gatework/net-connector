# frozen_string_literal: true

require_relative "../progress"
require_relative "topology/presentation"
require_relative "diagnostic"

module Net
  module Connector
    module Netdisco
      # 将备份与拓扑结果适配到统一的终端进度，不向通用组件引入 Netdisco 依赖。
      class Progress < Net::Connector::Progress
        # 备份入口保留清单对象接口，显示由公共批次组件处理。
        def plan(plan, parallel:, limit_per_vendor: nil)
          @operation_mode = false
          mode = limit_per_vendor ? "抽样（每厂商最多 #{limit_per_vendor} 台）" : "全量"
          super(total: plan.inventory.size, selected: plan.ready.size, parallel: parallel, label: mode)
        end

        # 设备对象只在领域入口转换为显示身份。
        def start(device, label: "备份")
          super(host: device.host, label: "#{label}（#{device.vendor}）")
        end

        # 分别展示已保存、设备报告上传和服务器核验状态。
        def result(outcome)
          error_code = diagnostic_code(outcome)
          message = case outcome.status
                    when :backed_up then "备份已保存（#{outcome.backup.bytes} 字节）"
                    when :reported_uploaded
                      outcome.backup&.verification == :server_verified ? "配置已归档（#{outcome.backup.server_bytes} 字节）" :
                        "设备报告上传完成；服务器文件尚未核验"
                    when :saved_with_error then "备份有产物但未完全成功（#{error_code || outcome.status}）"
                    when :reported_with_error then "设备报告上传但收尾异常（#{error_code || outcome.status}）"
                    else "未完成（#{error_code || outcome.status}）"
                    end
          super(host: outcome.device.host, success: outcome.success?, duration_ms: outcome.duration_ms, message: message, error_code: error_code)
        end

        # 成功策略、核验状态和回调诊断仍使用备份领域报告。
        def finish(report)
          return unless @enabled

          summary = report.statistics
          failures = report.outcomes.reject { |item| item.success? || %i[filtered sample_limit].include?(item.status) }
                           .group_by { |item| diagnostic_code(item) || item.status }.transform_values(&:size)
          super(success: report.policy_success?, **summary.slice(:succeeded, :partial, :failed, :skipped), failures: failures)
          unverified = summary[:verification]&.fetch(:unverified, 0) || 0
          write(nil, "其中 #{unverified} 台仅设备报告上传完成，服务器文件尚未核验") if unverified.positive?
          return unless !report.callback_errors.empty? || report.report_error

          write(nil, "回调异常 #{report.callback_errors.size}，报告错误 #{summary[:report_error] || "无"}")
        end

        # 清空上一阶段计数，初始化本次拓扑操作的任务规模与计时。
        def operation_plan(devices, parallel:, label:)
          @mutex.synchronize do
            @operation_neighbors = @operation_changes = @operation_skipped = @operation_pending = 0
            @operation_mode = true
            @total = devices.size
            @completed = @active = @succeeded = @failed = 0
            @stages.clear
            @task_started.clear
            @run_started = monotonic
            emit(nil, "#{label} | 本次 #{@total} 台；并发 #{parallel}")
          end
        end

        # 在共享锁内累计拓扑结果、邻居及变更数，并刷新安全进度。
        def operation_result(device:, status:, duration_ms:, error_code: nil, neighbors: 0, changes: 0, issues: [])
          error_code = Diagnostic.new(error_code: error_code).error_code
          @mutex.synchronize do
            @completed += 1
            @active -= 1
            @stages.delete(device.host)
            @task_started.delete(device.host)
            failed = Topology::Presentation::FAILURES.include?(status)
            succeeded = !failed
            @operation_pending += 1 unless issues.empty?
            skipped = status == :unsupported_operation
            @operation_neighbors += neighbors
            @operation_changes += changes
            if skipped
              @operation_skipped += 1
            elsif succeeded
              @succeeded += 1
            else
              @failed += 1
            end
            @failures[error_code || status] += 1 unless succeeded || skipped
            if @verbose || failed
              label = Topology::Presentation.status(status, changes: changes)
              reasons = issues.empty? ? "" : "；#{Topology::Presentation.issues(issues)}"
              emit(device.host, "#{label}；耗时 #{duration_ms} ms#{error_code ? "（#{error_code}）" : ""}#{reasons}")
            elsif !@tty && ((@completed % 25).zero? || @completed == @total)
              emit(nil, status_line)
            end
            refresh
          end
        end

        # 输出拓扑批次的最终状态计数和完成判断。
        def finish_operations(success:, counts:)
          failed = counts.any? { |status, count| Topology::Presentation::FAILURES.include?(status) && count.positive? }
          result = success ? "完成" : (failed ? "未完成" : "存在待处理项")
          write(nil, "拓扑批次结束：#{counts.map { |status, count| "#{Topology::Presentation.status(status)} #{count} 台" }.join("，")}；结果 #{result}")
        end

        private

        # 拓扑进度保留待核实项计数，备份使用通用成功与失败计数。
        def progress_counts
          @operation_mode ? "完成 #{@completed} 待核实 #{@operation_pending} 失败 #{@failed}" : super
        end

        # 与持久化摘要采用同一诊断白名单，保留领域结果自身的原始错误字段。
        def diagnostic_code(outcome)
          (outcome.diagnostic || Diagnostic.new(error_code: outcome.error_code)).error_code
        end

      end
    end
  end
end
