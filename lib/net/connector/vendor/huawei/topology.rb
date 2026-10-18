# frozen_string_literal: true

require_relative "../../device/base"
require_relative "../../device/topology/strategy"
require_relative "../../device/topology/interface_blocks"

module Net
  module Connector
    module Vendor
      class Huawei < Net::Connector::Base
        # VRP 简表支持统一的 LLDP 读取；不假设不同 VRP 的提交与保存阶段相同。
        class Topology < Net::Connector::Topology::Strategy
          include Net::Connector::Topology::InterfaceBlocks

          HEADER = /^[ \t]*Local Intf[ \t]+Neighbor Dev[ \t]+Neighbor Intf[ \t]+Exptime/i
          private_constant :HEADER

          def self.supports?(capability) = %i[neighbors interface_descriptions].include?(capability)

          def neighbor_command = "display lldp neighbor brief"

          def neighbor_template(_output) = "huawei/display_lldp_neighbor_brief.textfsm"

          def description_template = "huawei/display_current_configuration.textfsm"

          def expected_neighbor_count(output, _template)
            return unless output.match?(HEADER)

            neighbor_lines(output).size
          end

          def empty_neighbor_output?(output) = output.match?(HEADER) && neighbor_lines(output).empty?

          # VRP 的端口类型和编号允许用空格分开；身份比较去掉该空格。
          def interface_key(name) = super(name.delete(" \t"))

          private

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
