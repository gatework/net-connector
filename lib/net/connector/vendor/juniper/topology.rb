# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/interfaces/strategy"

module Net
  module Connector
    module Vendor
      class Juniper < Net::Connector::Base
        # 只读 LLDP 和已提交的接口描述；写入需要独立验证候选配置所有权。
        class Topology < Net::Connector::Interfaces::Strategy
          # 声明 Junos 策略当前只提供邻居和描述读取能力。
          def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)

          # 返回候选配置隔离能力缺失的原因，阻止不安全的自动提交。
          def change_error_code = :candidate_isolation_unavailable

          # 返回 Junos 详细邻居查询并关闭本次输出分页。
          def neighbor_command = "show lldp neighbors detail | no-more"

          # 选择 Junos 详细邻居解析模板。
          def neighbor_template(_output) = "juniper/show_lldp_neighbors_detail.textfsm"

          # 逻辑单元的描述独立于物理端口，不能覆盖端口的 LLDP 身份。
          def description_key(row)
            unit = row.fetch("UNIT", "")
            unit.empty? ? interface_key(row.fetch("INTERFACE")) : "#{interface_key(row.fetch("INTERFACE"))}.#{unit}"
          end

          # 选择 Junos set 格式配置中的接口描述模板。
          def description_template = "juniper/show_configuration_display_set.textfsm"

          # 按本地接口记录起始行统计邻居详情的预期条目数。
          def expected_neighbor_count(output, _template) = output.scan(/^\s*Local Interface\s*:/i).size

          # 依据明确的无邻居回显或零计数确认空结果，未知输出不视为空。
          def empty_neighbor_output?(output)
            output.match?(/^\s*(?:No LLDP neighbors\.?|Total entries displayed\s*:\s*0)\s*$/i) &&
              !output.match?(/^\s*(?:Local Interface|Chassis (?:ID|Id)|Port ID|System name)\s*:/i)
          end

          # 不闭合的描述必须报错，不能把截断的首行当作完整描述。
          def decode_description(value) = Net::Connector::Interfaces::QuotedText.decode(value, host: @device.host, split_unquoted: true)
        end
      end
    end
  end
end
