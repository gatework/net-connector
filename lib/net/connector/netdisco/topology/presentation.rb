# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      module Topology
        # JSON 状态码保持稳定；终端、汇总和设备说明共用中文含义及分类统计。
        module Presentation
          STATUSES = { planned: "已生成计划", partial_planned: "已生成部分计划", unverified: "含待核实接口",
                       discovered: "发现完成", applied: "应用完成", partial_applied: "部分应用完成", manual_required: "需人工处理",
                       unsupported_operation: "不支持，已跳过", failed: "执行失败", partial: "执行部分失败",
                       missing_credentials: "缺少凭据", interrupted: "已中断", not_started: "未开始", offline_review: "离线重审" }.freeze
          REASONS = { unknown_neighbor_name: "邻居未提供名称", unknown_neighbor_interface: "邻居未提供端口",
                      ambiguous_neighbor: "同一接口存在多个邻居", interface_missing: "配置中未找到本地接口",
                      unsafe_description: "目标描述不符合安全约束" }.freeze
          FAILURES = %i[failed partial missing_credentials interrupted not_started].freeze

          # 已规划但没有变更时明确显示无需修改，避免读者将 planned 理解为已经执行。
          def self.status(value, changes: nil)
            return "无需修改" if value.to_sym == :planned && changes == 0

            STATUSES.fetch(value.to_sym, value.to_s)
          end

          # 原因码只作受控回退，既不显示设备原文，也不省略尚未确认的问题。
          def self.reason(value) = REASONS.fetch(value.to_sym, value.to_s)

          # 汇总逐接口的问题数量，不把身份不足与设备连接或命令失败混为一谈。
          def self.issues(rows)
            rows.map { |row| row[:code] }.tally.map { |code, count| "#{reason(code)} #{count} 个接口" }.join("；")
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
            return "未完成" if summary[:orchestration_error_type] || summary[:interrupted] || summary[:progress_error]
            return "完成" if summary[:success]
            return "执行存在失败" if summary.fetch(:statistics).fetch(:failed).positive?

            return "没有可处理设备" if summary[:devices].empty?

            { plan: "已生成计划，存在待修正或待核实项", discover: "发现结束，仍有待核实接口",
              apply: "应用结束，仍有待处理项" }.fetch(summary[:mode], "存在待处理项")
          end
        end
      end
    end
  end
end
