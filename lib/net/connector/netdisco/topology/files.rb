# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "../../storage/atomic_file"
require_relative "../../device/topology"
require_relative "presentation"

module Net
  module Connector
    module Netdisco
      module Topology
        # 按备份的设备命名规则导出 CLI 命令与人工审阅记录，不执行任何设备命令。
        module Files
          # 先落盘每台设备的命令和说明，再由入口提交整批审批计划；任何写入失败均阻止应用。
          def self.write_plan(directory:, device:, outcome:)
            stem = device.backup_filename(style: :hostname_ip).delete_suffix(".txt")
            outcome[:name] = device.name
            outcome[:device_report] = File.join(directory, "devices", stem + ".txt")
            plan = outcome[:plan]
            if plan && !plan.commands.empty?
              Net::Connector::Topology.validate_plan!(plan, host: device.host, vendor: device.vendor)
              contents = plan.commands.join("\n") + "\n"
              path = File.join(directory, "scripts", stem + ".cfg")
              FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
              Storage::AtomicFile.write(path, contents)
              outcome[:script_file] = path
              outcome[:script_sha256] = Digest::SHA256.hexdigest(contents)
            end
            write_report(outcome)
          end

          # 发现后写入审阅说明，应用或中断收尾时以最终回执更新；无变更也保留设备说明。
          def self.write_report(outcome)
            path = outcome[:device_report]
            return unless path

            lines = ["设备：#{text(outcome[:name])}（#{text(outcome[:host])}）", "厂商：#{text(outcome[:vendor])}",
                     "状态：#{Presentation.status(outcome[:status], changes: outcome.fetch(:changes, 0))}；候选变更：#{outcome.fetch(:changes, 0)}",
                     outcome[:script_file] ? "命令文件：#{outcome[:script_file]}" : "命令文件：未生成（没有已核实的配置变更）"]
            lines << "命令校验 SHA-256：#{outcome[:script_sha256]}" if outcome[:script_sha256]
            lines << "诊断：#{text(outcome.dig(:diagnostic, :error_code))}" if outcome[:diagnostic]
            lines << "配置命令来自本次计划；文件生成不表示已经下发，执行结果以状态和设备回执为准。"
            lines.concat(outcome.fetch(:neighbors, []).map do |row|
              "#{text(row[:interface])} #{text(row[:status])} 现有=#{row[:current].inspect} 目标=#{row[:expected].inspect}"
            end)
            lines.concat(outcome.fetch(:issues, []).map { |issue| "未核实：#{text(issue[:interface])} #{text(Presentation.reason(issue[:code]))}" })
            FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
            Storage::AtomicFile.write(path, lines.join("\n") + "\n")
          end

          # 设备元数据只用于单行展示，控制符不能影响终端或伪造报告行。
          def self.text(value) = value.to_s.gsub(/[[:cntrl:]]/, " ")
          private_class_method :text
        end
      end
    end
  end
end
