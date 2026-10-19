# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/interfaces/immediate_strategy"

module Net
  module Connector
    module Vendor
      class H3c < Net::Connector::Base
        # 适配 H3C LLDP 表头与接口视图，数量核对失败时禁止继续规划变更。
        class Topology < Net::Connector::Interfaces::ImmediateStrategy
          TABLE_HEADER = /^\s*(?:System Name\s+Local Interface\b|(?:Local Interface|LocalIf)\s+)/i
          # H3C 提供 LLDP 邻居、配置描述读取和描述变更。
          def self.supports?(capability)
            %i[neighbors interface_descriptions interface_description_changes].include?(capability)
          end

          # 读取设备的 LLDP 邻居列表。
          def neighbor_command = "display lldp neighbor-information list"

          # 从运行配置解析当前接口描述。
          def description_template = "h3c/display_current_configuration.textfsm"

          # 进入系统视图以修改接口描述。
          def enter_configuration_command = "system-view"

          # 返回用户视图读回；保存交给后续独立阶段。
          def leave_configuration_commands = ["return"]

          # 只认可本厂商明确的保存完成行，设备提示符返回本身不能证明持久化。
          def persistence_pattern = /\ASaved the current configuration to mainboard device successfully\.\z/i

          # H3C 列顺序由同一模板按表头分支；策略先拒绝未知表头。
          def neighbor_template(output)
            return "h3c/display_lldp_neighbor_information_list.textfsm" if output.match?(TABLE_HEADER)

            raise ParsingError.new("H3C LLDP table header was not recognized", code: :unrecognized_output,
                                   host: @device.host, phase: :discover)
          end

          # 按表头后的有效数据行计数，未知行会让完整性校验失败。
          def expected_neighbor_count(output, _template)
            local_column = output.match?(/^[ \t]*System Name[ \t]+Local Interface\b/i) ? 1 : 0
            lines = neighbor_lines(output)
            return unless lines.all? do |line|
              interface = line.split.fetch(local_column, nil)
              interface&.match?(/\A(?:[A-Za-z][A-Za-z-]*\d+(?:\/\d+)+|(?:Bridge-Aggregation|BAGG|Route-Aggregation|RAGG)\d+)(?:[:.]\d+)*\z/i)
            end

            lines.size
          end

          # 表头之后的未知行不能作为零邻居证据。
          def empty_neighbor_output?(output) = neighbor_lines(output).empty?

          # 在接口视图设置描述后用 quit 返回系统视图。
          def change_commands(change)
            Net::Connector::Interfaces::InterfaceDescription.commands(interface: change.interface, description: change.new_description, leave: "quit")
          end

          private

          # 过滤表头、分隔线和设备提示符，保留待解析的邻居行。
          def neighbor_lines(output)
            output.lines("\n").drop_while { |line| !line.match?(TABLE_HEADER) }.map(&:strip).reject do |line|
              line.empty? || line.match?(TABLE_HEADER) || line.match?(/\A[-=+ ]+\z/) ||
                line.match?(/\A(?:<[^>]+>|\[[^\]]+\])\z/)
            end
          end
        end
      end
    end
  end
end
