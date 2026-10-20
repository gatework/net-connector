# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      class CLI
        # 简要帮助从实际解析器筛选；范例按执行模式生成完整命令。
        module Help
          COMMON = %w[init config env-file show-config directory interactive non-interactive host hosts name exclude-name vendor
                      plan inventory-only parallel refresh-inventory json quiet no-progress help help-all examples].freeze

          # 从完整解析器帮助中筛选常用选项，避免维护重复的帮助文本。
          def self.common(parser, mode: :backup)
            flags = mode == :topology ? COMMON + %w[discover apply limit] : COMMON
            keep = true
            parser.to_s.lines.select do |line|
              flag = line[/--([a-z-]+)/, 1]
              keep = flags.include?(flag) if flag
              keep
            end.join
          end

          # 按备份、TFTP 或拓扑模式生成可直接调整使用的命令范例。
          def self.examples(program:, mode:)
            command = "ruby #{File.basename(program)}"
            cases = if mode == :topology
                      [["预览过滤后的清单", "--inventory-only --name edge --cache-only"],
                       ["发现邻居", "--discover --hosts 192.0.2.10-20"],
                       ["生成只读计划", "--plan --host 192.0.2.10"],
                       ["明确应用并读回保存", "--apply --host 192.0.2.10"]]
                    elsif mode == :tftp
                      [["预览待上传设备", "--plan --hosts 192.0.2.10-20"],
                       ["单台上传，服务器沿用配置", "--host 192.0.2.10"],
                       ["连续 IP 范围并发上传", "--hosts 192.0.2.10-20 --parallel 8"],
                       ["上传并核验服务器文件", "--host 192.0.2.10 --tftp-root /srv/tftp --success-policy verified"]]
                    else
                      [["沿用配置执行备份", ""], ["预览连续 IP 范围", "--plan --hosts 192.0.2.10-20"],
                       ["单台设备配置备份", "--host 192.0.2.10"],
                       ["按名称筛选并排除设备", "--name szx10 --exclude-name csw,asw,wlc --parallel 8"],
                       ["使用数据库清单预览", "--config examples/inventory.yml --plan"]]
                    end
            cases.unshift(["首次生成缺失配置后退出", "--init --non-interactive"])
            ["常用示例（IP 请替换为实际清单地址）：",
             *cases.map { |label, arguments| "  #{label}：\n    #{command} #{arguments}" },
             "包含条件取交集，排除优先；同类参数可逗号分隔或重复传参。"].join("\n")
          end
        end
      end
    end
  end
end
