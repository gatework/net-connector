# frozen_string_literal: true

require_relative "../../operations/topology/immediate_strategy"

module Net
  module Connector
    module H3c
      class Topology < Operations::Topology::ImmediateStrategy
        TABLE_HEADER = /^\s*(?:System Name\s+Local Interface\b|(?:Local Interface|LocalIf)\s+)/i
        # H3C 提供 LLDP 邻居、配置描述读取和描述变更。
        def self.supports?(capability)
          %i[neighbors interface_descriptions interface_description_changes].include?(capability)
        end

        # 读取设备的 LLDP 邻居列表。
        def neighbor_command = "display lldp neighbor-information list"

        # 从运行配置解析当前接口描述。
        def description_template = "h3c_interface_descriptions.textfsm"

        # 进入系统视图以修改接口描述。
        def enter_configuration = "system-view"

        # 返回用户视图读回；保存交给后续独立阶段。
        def leave_configuration = ["return"]

        def persistence_pattern = /\ASaved the current configuration to mainboard device successfully\.\z/i

        # H3C 不同版本的列顺序不同，按表头选对应模板。
        def neighbor_template(output)
          return "h3c_lldp_name_first.textfsm" if output.match?(/^\s*System Name\s+Local Interface\b/im)
          return "h3c_lldp_local_first.textfsm" if output.match?(/^\s*(?:Local Interface|LocalIf)\s+/im)

          raise ParsingError.new("H3C LLDP table header was not recognized", code: :unrecognized_output,
                                 host: @device.host, phase: :discover)
        end

        # 按表头后的有效数据行计数，未知行会让完整性校验失败。
        def expected_neighbor_count(output, template)
          local_column = template == "h3c_lldp_name_first.textfsm" ? 1 : 0
          lines = neighbor_lines(output)
          return unless lines.all? do |line|
            interface = line.split.fetch(local_column, nil)
            interface&.match?(/\A[A-Za-z][A-Za-z-]*\d+(?:\/\d+)+\z/)
          end

          lines.size
        end

        # 表头之后的未知行不能作为零邻居证据。
        def empty_neighbor_output?(output) = neighbor_lines(output).empty?

        # 在接口视图设置描述后用 quit 返回系统视图。
        def change_commands(change)
          InterfaceDescription.commands(interface: change.interface, description: change.new_description, leave: "quit")
        end

        private

        # 过滤表头、分隔线和设备提示符，保留待解析的邻居行。
        def neighbor_lines(output)
          output.lines.drop_while { |line| !line.match?(TABLE_HEADER) }.map(&:strip).reject do |line|
            line.empty? || line.match?(TABLE_HEADER) || line.match?(/\A[-=+ ]+\z/) ||
              line.match?(/\A(?:<[^>]+>|\[[^\]]+\])\z/)
          end
        end
      end
    end
  end
end
