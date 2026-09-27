# frozen_string_literal: true

require_relative "../../operations/topology/strategy"

module Net
  module Connector
    module PaloAlto
      class Topology < Operations::Topology::Strategy
        # 候选配置缺少经固件实验确认的所有权/commit 协议，暂只提供读取能力。
        def self.supports?(capability)
          %i[neighbors interface_descriptions].include?(capability)
        end

        def change_error_code = :candidate_isolation_unavailable

        # 读取各本机接口的 LLDP 邻居详情。
        def neighbor_command = "show lldp neighbors all"

        # 从 set 格式配置解析接口备注。
        def description_template = "palo_alto_interface_descriptions.textfsm"

        # 进入候选配置视图。
        def enter_configuration = "configure"

        # 提交候选配置后退出配置视图。
        def finish_commands = ["commit", "exit"]

        # 只计入非空邻居块，跳过没有对端的本机接口。
        def expected_neighbor_count(output, _template)
          neighbor_blocks(output).count { |block| !empty_neighbor_block?(block) }
        end

        # 输出必须明确说明无邻居，或每个本机接口块都明确为空。
        def empty_neighbor_output?(output)
          return true if output.match?(/No LLDP neighbors/i)

          blocks = neighbor_blocks(output)
          !blocks.empty? && blocks.all? { |block| empty_neighbor_block?(block) }
        end

        private

        # PAN-OS 会列出启用 LLDP、但没有邻居的本机接口；只有明确为空的
        # Neighbor information 块可跳过，缺字段的非空块继续交给数量校验拒绝。
        def neighbor_blocks(output)
          output.split(/^\s*Local information:\s*$/i).select { |block| block.match?(/^\s*Local interface:\s*\S+/i) }
        end

        # 邻居字段区只有空行和提示符时，才视为明确的空块。
        def empty_neighbor_block?(block)
          tail = block.split(/^\s*Neighbor information:\s*$/i, 2)
          tail.size == 2 && tail.last.lines.all? { |line| line.strip.empty? || line.match?(/^\S+[>#]\s*$/) }
        end

        public

        # 模板按行读取；未闭合的引号表示证据不完整，不能把首行当成旧描述。
        def decode_description(value)
          value = value.strip
          value.start_with?('"') ? Shellwords.split(value).join(" ") : value
        rescue ArgumentError
          raise ParsingError.new("PAN-OS interface comment is not a complete single-line value",
                                 code: :unrecognized_output, host: @device.host, phase: :parse)
        end

        # 用 PAN-OS set 语法生成接口备注变更。
        def change_commands(change)
          [%Q(set network interface ethernet #{change.interface} comment "#{change.new_description}")]
        end

        # commit 可能耗时较长，单独放宽该命令的超时。
        def script_command(command)
          command == "commit" ? Command.new(command, timeout: 300) : command
        end
      end
    end
  end
end
