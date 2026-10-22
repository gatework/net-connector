# frozen_string_literal: true

require "yaml"
require "ctx_cli/initialization"
require "ctx_cli/terminal"
require_relative "../settings"
require_relative "../../config"

module Net
  module Connector
    module Netdisco
      module Config
        # 只生成公开策略；问答全部完成并验证后才原子写入，不覆盖既有目录项。
        class Initializer
          # 绑定配置问答的输入输出，保留调用方对 IO 的所有权。
          def initialize(input: $stdin, output: $stderr)
            @input, @output = input, output
            @writer = CtxCli::Initialization.new(prefix: ".net-connector-config-")
          end

          # 完成默认值校验与可选问答后独占发布新配置，不覆盖已存在文件。
          def create(path:, document:, interactive: nil, mode: nil, inherited_parallel: Settings::DEFAULT_PARALLEL)
            raise ArgumentError, "config path must be a nonempty String" unless path.is_a?(String) && !path.empty?
            unless interactive.nil? || [true, false].include?(interactive)
              raise ArgumentError, "interactive must be true, false or nil"
            end
            return :exists if existing?(path)

            values = YAML.safe_load(YAML.dump(document), aliases: false)
            validate!(values)
            interactive = CtxCli::Terminal.tty?(@input, @output) if interactive.nil?
            configure(values, mode: mode, inherited_parallel: inherited_parallel) if interactive && answer("进入交互配置？[y/N]", "n").casecmp?("y")
            validate!(values)
            name = mode == :topology ? "topology" : "backup"
            write(path, Net::Connector::Config.dump(values, name: name, path: path))
          end

          # 发布环境文件模板；不收集或复制进程中的密码，也不覆盖已有文件。
          def create_environment(path:, contents:)
            return :exists if existing?(path)

            write(path, contents)
          end

          private

          # 判断已有配置是否为普通文件；符号链接或其他类型不作为可用配置。
          def existing?(path) = @writer.existing?(path)

          # 通过完整策略快照校验候选文档，拒绝生成不可执行的配置。
          def validate!(document)
            Settings.new(env: {}, defaults: Config.parse(document)).snapshot(mode: :show_config)
          end

          # 显示有效默认值；空输入可由字段选择沿用或保留继承，输入结束则中止生成。
          def answer(label, default, blank: default)
            @output.print "#{label}#{default.nil? ? "" : " [#{default}]"}："
            @output.flush
            line = @input.gets("\n")
            raise EOFError, "configuration input ended before completion" unless line

            value = line.chomp("\n").chomp("\r").strip
            value.empty? ? blank : value
          end

          # 循环读取并校验单个配置字段，只有合法回答才更新候选配置。
          def field(document, section, key, label, default, list: false)
            values = (document[section] ||= {})
            previous = values.fetch(key, default)
            label = "#{label}（留空继承）" if key == "parallel" && !values.key?(key)
            loop do
              displayed = previous.is_a?(Array) ? previous.join(",") : previous&.to_s
              text = answer(label, displayed, blank: key == "parallel" ? nil : displayed)
              return if key == "parallel" && text.nil?

              value = if list
                        text.to_s.empty? ? [] : text.split(",", -1).map(&:strip)
                      elsif key == "parallel"
                        Integer(text, exception: false)
                      else
                        text
                      end
              candidate = values.merge(key => value)
              begin
                validate!(document.merge(section => candidate))
                values[key] = value
                return
              rescue ArgumentError
                @output.puts "值无效，请重新输入。"
              end
            end
          end

          # 按清单来源和业务模式逐项填写非敏感配置。
          def configure(document, mode: nil, inherited_parallel:)
            field(document, "netdisco", "source", "清单来源 http/postgres", "http")
            if document.dig("netdisco", "source") == "http"
              field(document, "netdisco", "url", "清单 URL", mode.nil? ? "https://netdisco.example.invalid" : nil)
            end
            %w[include_hosts exclude_hosts include_names exclude_names include_models exclude_models].each do |key|
              field(document, "inventory", key, key, [], list: true)
            end
            field(document, "inventory", "name_match", "名称匹配 contains/prefix/glob", "contains")
            field(document, "inventory", "model_match", "型号匹配 contains/prefix/glob", "contains")
            %w[include_vendors exclude_vendors].each { |key| field(document, "inventory", key, key, [], list: true) }
            if document.key?("topology")
              field(document, "topology", "parallel", "拓扑并发数 1..500", inherited_parallel)
              field(document, "topology", "directory", "拓扑报告目录", "./topologys")
            else
              field(document, "backup", "parallel", "并发数 1..500", inherited_parallel)
              field(document, "backup", "directory", "备份目录", "./backups")
              field(document, "tftp", "server", "TFTP 服务器", nil) if mode.nil? || mode == :tftp
            end
          end

          # 公开文档已校验；排他发布、同步与清理由公共初始化器负责。
          def write(path, contents) = @writer.create(path: path, contents: contents)
        end
      end
    end
  end
end
