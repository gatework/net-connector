# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      module Topology
        # JSON 状态码保持稳定；终端、汇总和设备说明共用中文含义及分类统计。
        module Presentation
          STATUSES = { planned: "plan generated", partial_planned: "partial plan generated", unverified: "contains unverified interfaces",
                       discovered: "discovery complete", applied: "apply complete", partial_applied: "partial apply complete", manual_required: "manual action required",
                       unsupported_operation: "unsupported; skipped", failed: "execution failed", partial: "execution partially failed",
                       missing_credentials: "missing credentials", interrupted: "interrupted", not_started: "not started", offline_review: "offline review" }.freeze
          REASONS = { unknown_neighbor_name: "neighbor name missing", unknown_neighbor_interface: "neighbor port missing",
                      ambiguous_neighbor: "multiple neighbors on one interface", interface_missing: "local interface not found in configuration",
                      unsafe_description: "target description violates safety constraints" }.freeze
          FAILURES = %i[failed partial missing_credentials interrupted not_started].freeze

          # 已规划但没有变更时明确显示无需修改，避免读者将 planned 理解为已经执行。
          def self.status(value, changes: nil)
            return "no changes needed" if value.to_sym == :planned && changes == 0

            STATUSES.fetch(value.to_sym, value.to_s)
          end

          # 原因码只作受控回退，既不显示设备原文，也不省略尚未确认的问题。
          def self.reason(value) = REASONS.fetch(value.to_sym, value.to_s)

          # 汇总逐接口的问题数量，不把身份不足与设备连接或命令失败混为一谈。
          def self.issues(rows)
            rows.map { |row| row[:code] }.tally.map { |code, count| "#{reason(code)} #{count} interfaces" }.join("; ")
          end

          # 设备与接口分别统计；含待核实项的设备也可能拥有可执行的局部计划。
          def self.statistics(outcomes)
            { collected: outcomes.count { |item| !FAILURES.include?(item[:status]) && item[:status] != :unsupported_operation },
              failed: outcomes.count { |item| FAILURES.include?(item[:status]) || item[:event_error_type] },
              unchanged: outcomes.count { |item| item[:status] == :planned && item.fetch(:changes, 0).zero? },
              change_devices: outcomes.count { |item| item.fetch(:changes, 0).positive? },
              changes: outcomes.sum { |item| item.fetch(:changes, 0) },
              review_devices: outcomes.count { |item| !item.fetch(:issues, []).empty? },
              review_interfaces: outcomes.sum { |item| item.fetch(:issues, []).size } }
          end

          # 只读计划中有差异或未知证据表示待处理，不能把生成计划描述为配置下发完成。
          def self.result(summary)
            return "incomplete" if summary[:orchestration_error_type] || summary[:interrupted] || summary[:progress_error]
            return "complete" if summary[:success]
            return "execution contains failures" if summary.fetch(:statistics).fetch(:failed).positive?

            return "no eligible devices" if summary[:devices].empty?

            { plan: "plan generated; corrections or verification still required", discover: "discovery finished; unverified interfaces remain",
              apply: "apply finished; pending items remain" }.fetch(summary[:mode], "pending items remain")
          end
        end
      end
    end
  end
end
