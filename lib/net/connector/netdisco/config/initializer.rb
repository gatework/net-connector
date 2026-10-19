# frozen_string_literal: true

require "yaml"
require "tempfile"
require_relative "../settings"

module Net
  module Connector
    module Netdisco
      module Config
        # 只生成公开策略；问答全部完成并验证后才原子写入，不覆盖既有目录项。
        class Initializer
          # 绑定配置问答的输入输出，保留调用方对 IO 的所有权。
          def initialize(input: $stdin, output: $stderr)
            @input, @output = input, output
          end

          # 完成默认值校验与可选问答后独占发布新配置，不覆盖已存在文件。
          def create(path:, document:, interactive: nil, mode: nil)
            raise ArgumentError, "config path must be a nonempty String" unless path.is_a?(String) && !path.empty?
            unless interactive.nil? || [true, false].include?(interactive)
              raise ArgumentError, "interactive must be true, false or nil"
            end
            return :exists if existing?(path)

            values = YAML.safe_load(YAML.dump(document), aliases: false)
            validate!(values)
            interactive = @input.respond_to?(:tty?) && @input.tty? && @output.respond_to?(:tty?) && @output.tty? if interactive.nil?
            configure(values, mode: mode) if interactive && answer("进入交互配置？[y/N]", "n").casecmp?("y")
            validate!(values)
            write(path, YAML.dump(values))
          end

          # 发布环境文件模板；不收集或复制进程中的密码，也不覆盖已有文件。
          def create_environment(path:, contents:)
            return :exists if existing?(path)

            write(path, contents)
          end

          private

          # 判断已有配置是否为普通文件；符号链接或其他类型不作为可用配置。
          def existing?(path)
            stat = File.lstat(path)
            raise ArgumentError, "config path must be a regular file" unless stat.file?

            true
          rescue Errno::ENOENT
            false
          end

          # 通过完整策略快照校验候选文档，拒绝生成不可执行的配置。
          def validate!(document)
            Settings.new(env: {}, defaults: Config.parse(document)).snapshot(mode: :show_config)
          end

          # 读取一行配置回答，空输入沿用默认值，输入结束则中止生成。
          def answer(label, default)
            @output.print "#{label}#{default.nil? ? "" : " [#{default}]"}："
            @output.flush
            line = @input.gets("\n")
            raise EOFError, "configuration input ended before completion" unless line

            value = line.chomp("\n").chomp("\r").strip
            value.empty? ? default : value
          end

          # 循环读取并校验单个配置字段，只有合法回答才更新候选配置。
          def field(document, section, key, label, default, list: false)
            values = (document[section] ||= {})
            previous = values.fetch(key, default)
            loop do
              text = answer(label, previous.is_a?(Array) ? previous.join(",") : previous&.to_s)
              value = if list
                        text.to_s.empty? ? [] : text.split(",").map(&:strip)
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
          def configure(document, mode: nil)
            field(document, "netdisco", "source", "清单来源 http/postgres", "http")
            if document.dig("netdisco", "source") == "http"
              field(document, "netdisco", "url", "清单 URL", mode.nil? ? "https://netdisco.example.invalid" : nil)
            end
            %w[include_hosts exclude_hosts include_names exclude_names].each do |key|
              field(document, "inventory", key, key, [], list: true)
            end
            field(document, "inventory", "name_match", "名称匹配 contains/prefix/glob", "contains")
            %w[include_vendors exclude_vendors].each { |key| field(document, "inventory", key, key, [], list: true) }
            if document.key?("topology")
              field(document, "topology", "parallel", "拓扑并发数 1..500", 4)
              field(document, "topology", "directory", "拓扑报告目录", "./topologys")
            else
              field(document, "backup", "parallel", "并发数 1..500", 4)
              field(document, "backup", "directory", "备份目录", "./backups")
              field(document, "tftp", "server", "TFTP 服务器", nil) if mode.nil? || mode == :tftp
            end
          end

          # 尝试关闭目录与临时文件全部句柄，清理失败不覆盖原始异常。
          def close_files(file, parent, primary)
            Thread.handle_interrupt(Exception => :never) do
              error = nil
              [-> { parent&.close }, -> { file&.close! }].each do |close|
                begin
                  close.call
                rescue Exception => failure # rubocop:disable Lint/RescueException -- 两个资源均尝试关闭，保留首个故障。
                  error ||= failure
                end
              end
              raise error if error && !primary
            end
          end

          # 先写入并同步私有临时文件，再以独占硬链接发布完整配置并同步目录。
          # 最终路径只在内容写全并同步后出现；已有目标由独占链接保护，取消也不能留下半份配置。
          def write(path, contents)
            directory = File.realpath(File.dirname(File.expand_path(path)))
            destination = File.join(directory, File.basename(path))
            file = parent = nil
            begin
              Thread.handle_interrupt(Exception => :never) { file = Tempfile.new([".net-connector-config-", ".tmp"], directory) }
              file.binmode
              file.chmod(0o600)
              file.write(contents)
              file.flush
              file.fsync
              begin
                File.link(file.path, destination)
              rescue Errno::EEXIST
                return :exists if existing?(destination)

                raise
              end
              Thread.handle_interrupt(Exception => :never) { parent = File.open(directory, File::RDONLY | File::NOFOLLOW) }
              parent.fsync
              :created
            rescue Exception => failure # rubocop:disable Lint/RescueException -- 清理不能覆盖输入取消或发布故障。
              primary = failure
              raise
            ensure
              close_files(file, parent, primary)
            end
          end
        end
      end
    end
  end
end
