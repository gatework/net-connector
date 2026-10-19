# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/topology/strategy"

module Net
  module Connector
    module Vendor
      class Fortinet < Net::Connector::Base
        # LLDP 命令自 7.6.3 改名；先核对只读版本信息，不通过失败重试猜测方言。
        class Topology < Net::Connector::Topology::Strategy
          # 声明本策略仅支持邻居发现和描述读取，不允许描述配置变更。
          def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)

          # 在当前会话内选择 FortiOS 实际支持的 LLDP 查询命令。
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

          # 选择 FortiOS 完整配置的接口描述解析模板。
          def description_template = "fortinet/show_full_configuration.textfsm"

          # 接口名称大小写与设备配置一致，不套用 Cisco 接口简称。
          def interface_key(name) = decode_description(name)

          # 保留 FortiOS 接口原名，不借用其他厂商的接口简写规则。
          def configuration_interface(name) = name

          # 按 FortiOS 引号和分词规则解码接口描述。
          def decode_description(value) = Net::Connector::Topology::QuotedText.decode(value, host: @device.host, split_unquoted: true)

          # 模板只接受当前视图的顶层接口表，嵌套 VDOM 或残缺配置不能冒充完整结果。
          def validate_descriptions!(config, rows)
            tables = config.scan(/^config system interface[ \t]*$/).size
            nested = config.match?(/^[ \t]+config system interface[ \t]*$/)
            table = config[/^config system interface[ \t]*\n(.*?)^end[ \t]*$/m, 1]
            expected = table&.scan(/^    edit[ \t]+([^\r\n]+)/)&.flatten
            names = expected&.map { |name| decode_description(name) }
            return if !nested && tables == 1 && names == rows.map { |row| interface_key(row.fetch("INTERFACE")) } &&
                      table.scan(/^    next[ \t]*$/).size == names.size

            raise ParsingError.new("FortiOS interface table is incomplete or outside the current view",
                                   code: :unrecognized_output, host: @device.host, phase: :parse)
          end

          # 选择 FortiOS LLDP 邻居回显模板。
          def neighbor_template(_output) = "fortinet/diagnose_lldp_rx_neighbor.textfsm"

          # 按邻居记录起始行统计预期条目数，防止解析静默遗漏。
          def expected_neighbor_count(output, _template) = output.scan(/^\s*\d+\s+port\b/).size

          # 诊断命令的空响应没有明确零邻居证据，不能推断为空拓扑。
          def empty_neighbor_output?(output) = output.match?(/^\s*No (?:LLDP )?neighbors\.?\s*$/i)
        end
      end
    end
  end
end
