# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/topology/strategy"

module Net
  module Connector
    module Vendor
      class Fortinet < Net::Connector::Base
        # LLDP 命令自 7.6.3 改名；先核对只读版本信息，不通过失败重试猜测方言。
        class Topology < Net::Connector::Topology::Strategy
          def self.supports?(capability) = capability == :neighbors

          def neighbor_command
            status = @device.execute_command("get system status").value!
            version = status.match(/^Version:[^\r\n]*\bv(\d+)\.(\d+)\.(\d+)\b/i)
            unless version
              raise ParsingError.new("FortiOS version was not recognized", code: :unrecognized_output,
                                     host: @device.host, phase: :discover)
            end
            release = version.captures.map(&:to_i)
            (release <=> [7, 6, 3]) >= 0 ? "diagnose lldp rx neighbor" : "diagnose lldprx neighbor"
          end

          def neighbor_template(_output) = "fortinet/diagnose_lldp_rx_neighbor.textfsm"

          def expected_neighbor_count(output, _template) = output.scan(/^\s*\d+\s+port\b/).size

          # 诊断命令的空响应没有明确零邻居证据，不能推断为空拓扑。
          def empty_neighbor_output?(output) = output.match?(/^\s*No (?:LLDP )?neighbors\.?\s*$/i)
        end
      end
    end
  end
end
