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
                      [["Preview filtered inventory", "--inventory-only --name edge --cache-only"],
                       ["Discover neighbors", "--discover --hosts 192.0.2.10-20"],
                       ["Generate a read-only plan", "--plan --host 192.0.2.10"],
                       ["Explicitly apply, read back and save", "--apply --host 192.0.2.10"]]
                    elsif mode == :tftp
                      [["Preview devices selected for upload", "--plan --hosts 192.0.2.10-20"],
                       ["Upload from one device using the configured server", "--host 192.0.2.10"],
                       ["Upload concurrently from an IP range", "--hosts 192.0.2.10-20 --parallel 8"],
                       ["Upload and verify server files", "--host 192.0.2.10 --tftp-root /srv/tftp --success-policy verified"]]
                    else
                      [["Back up using the configuration", ""], ["Preview an IP range", "--plan --hosts 192.0.2.10-20"],
                       ["Back up one device configuration", "--host 192.0.2.10"],
                       ["Filter by name and exclude devices", "--name szx10 --exclude-name csw,asw,wlc --parallel 8"],
                       ["Preview database inventory", "--config examples/inventory.yml --plan"]]
                    end
            cases.unshift(["Create missing configuration and exit", "--init --non-interactive"])
            ["Common examples (replace IPs with actual inventory addresses):",
             *cases.map { |label, arguments| "  #{label}:\n    #{command} #{arguments}" },
             "Intersect different inclusion types; exclusions take precedence. Repeat options or separate values with commas."].join("\n")
          end
        end
      end
    end
  end
end
