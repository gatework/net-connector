# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/interfaces/strategy"
require_relative "../../device/interfaces/blocks"

module Net
  module Connector
    module Vendor
      class Huawei < Net::Connector::Base
        # VRP 简表支持统一的 LLDP 读取；不假设不同 VRP 的提交与保存阶段相同。
        class Topology < Net::Connector::Interfaces::Strategy
          include Net::Connector::Interfaces::Blocks

          HEADER = /^[ \t]*Local Intf[ \t]+Neighbor Dev[ \t]+Neighbor Intf[ \t]+Exptime/i
          private_constant :HEADER

          # 声明本策略支持发现和描述读取，尚不允许配置描述修改。
          def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)

          # 返回华为 LLDP 邻居摘要查询命令。
          def neighbor_command = "display lldp neighbor brief"

          # 选择华为 LLDP 邻居摘要解析模板。
          def neighbor_template(_output) = "huawei/display_lldp_neighbor_brief.textfsm"

          # 选择华为当前配置的接口描述模板。
          def description_template = "huawei/display_current_configuration.textfsm"

          # 依据摘要中的邻居数据行统计预期解析条数。
          def expected_neighbor_count(output, _template)
            return unless output.match?(HEADER)

            neighbor_lines(output).size
          end

          # 只有存在合法摘要头且没有邻居行时才确认空邻居。
          def empty_neighbor_output?(output) = output.match?(HEADER) && neighbor_lines(output).empty?

          # VRP 的端口类型和编号允许用空格分开；身份比较去掉该空格。
          def interface_key(name) = super(name.delete(" \t"))

          private

          # 从华为摘要头之后筛选实际邻居行，排除标题和空白。
          def neighbor_lines(output)
            output.lines("\n").drop_while { |line| !line.match?(HEADER) }.drop(1).map(&:strip).reject do |line|
              line.empty? || line.match?(/\A[-=]+\z/) || line.match?(/\A(?:<[^>]+>|\[[^\]]+\])\z/)
            end
          end
        end
      end
    end
  end
end
