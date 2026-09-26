# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module Hillstone
      class Topology < Operations::Topology::Strategy
        # 山石提供 LLDP 邻居、配置描述读取和描述变更。
        def self.supports?(capability)
          %i[neighbors interface_descriptions interface_description_changes].include?(capability)
        end

        # 读取 LLDP 邻居信息。
        def neighbor_command = "show lldp neighbor-information"
        # 从运行配置解析接口描述。
        def description_template = "hillstone_interface_descriptions.textfsm"
        # 进入配置视图。
        def enter_configuration = "configure"
        # 退出配置视图并保存设备配置。
        def finish_commands = ["exit"] + @device.profile.save_commands

        # 用数据行和设备报告的总数交叉核对，避免遗漏邻居。
        def expected_neighbor_count(output, _template)
          reported = output[/Total lldp neighbor number:\s*(\d+)/i, 1]
          lines = neighbor_lines(output)
          return unless lines.all? { |line| line.match?(/\A\S+\s+ethernet\d+\/\d+\s/i) }
          return if reported && reported.to_i != lines.size

          lines.size
        end

        # 仅在列表为空且有明确零邻居证据时认可空表。
        def empty_neighbor_output?(output)
          neighbor_lines(output).empty? && (output.match?(/Total lldp neighbor number:\s*0\b/i) ||
            output.match?(/System Name\s+Local Interface/i))
        end

        # 复用公共接口描述命令。
        def change_commands(change)
          InterfaceDescription.commands(interface: change.interface, description: change.new_description)
        end

        private

        # 去掉命令、表头、总数和提示符，只保留邻居数据行。
        def neighbor_lines(output)
          output.lines.map(&:strip).reject do |line|
            line.empty? || line == neighbor_command || line.match?(/\ASystem Name\s+Local Interface\b/i) ||
              line.match?(/\ATotal lldp neighbor number:\s*\d+\.?\z/i) ||
              line.match?(/\A[-=+ ]+\z/) || line.match?(/\A\S+(?:#|\([MBF]\))\z/)
          end
        end
      end
    end
  end
end
