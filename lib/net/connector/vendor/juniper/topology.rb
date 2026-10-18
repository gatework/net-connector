# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/topology/strategy"

module Net
  module Connector
    module Vendor
      class Juniper < Net::Connector::Base
        # 只读 LLDP 和已提交的接口描述；写入需要独立验证候选配置所有权。
        class Topology < Net::Connector::Topology::Strategy
          def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)

          def change_error_code = :candidate_isolation_unavailable

          def neighbor_command = "show lldp neighbors detail | no-more"

          def neighbor_template(_output) = "juniper/show_lldp_neighbors_detail.textfsm"

          # 逻辑单元的描述独立于物理端口，不能覆盖端口的 LLDP 身份。
          def description_key(row)
            unit = row.fetch("UNIT", "")
            unit.empty? ? interface_key(row.fetch("INTERFACE")) : "#{interface_key(row.fetch("INTERFACE"))}.#{unit}"
          end

          def description_template = "juniper/show_configuration_display_set.textfsm"

          def expected_neighbor_count(output, _template) = output.scan(/^\s*Local Interface\s*:/i).size

          def empty_neighbor_output?(output)
            output.match?(/^\s*(?:No LLDP neighbors\.?|Total entries displayed\s*:\s*0)\s*$/i) &&
              !output.match?(/^\s*(?:Local Interface|Chassis (?:ID|Id)|Port ID|System name)\s*:/i)
          end

          # 不闭合的描述必须报错，不能把截断的首行当作完整描述。
          def decode_description(value) = Net::Connector::Topology::QuotedText.decode(value, host: @device.host, split_unquoted: true)
        end
      end
    end
  end
end
