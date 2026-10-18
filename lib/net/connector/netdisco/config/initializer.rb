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
          def initialize(input: $stdin, output: $stderr)
            @input, @output = input, output
          end

          def create(path:, document:, interactive: nil)
            raise ArgumentError, "config path must be a nonempty String" unless path.is_a?(String) && !path.empty?
            unless interactive.nil? || [true, false].include?(interactive)
              raise ArgumentError, "interactive must be true, false or nil"
            end
            return :exists if existing?(path)

            values = YAML.safe_load(YAML.dump(document), aliases: false)
            validate!(values)
            interactive = @input.respond_to?(:tty?) && @input.tty? && @output.respond_to?(:tty?) && @output.tty? if interactive.nil?
            configure(values) if interactive && answer("进入交互配置？[y/N]", "n").casecmp?("y")
            validate!(values)
            write(path, YAML.dump(values))
          end

          private

          def existing?(path)
            stat = File.lstat(path)
            raise ArgumentError, "config path must be a regular file" unless stat.file?

            true
          rescue Errno::ENOENT
            false
          end

          def validate!(document)
            Settings.new(env: {}, defaults: Config.parse(document)).snapshot(mode: :show_config)
          end

          def answer(label, default)
            @output.print "#{label}#{default.nil? ? "" : " [#{default}]"}："
            @output.flush
            line = @input.gets("\n")
            raise EOFError, "configuration input ended before completion" unless line

            value = line.chomp("\n").chomp("\r").strip
            value.empty? ? default : value
          end

          def field(document, section, key, label, default, list: false)
            values = (document[section] ||= {})
            previous = values.fetch(key, default)
            loop do
              text = answer(label, previous.is_a?(Array) ? previous.join(",") : previous&.to_s)
              value = if list
                        text.to_s.empty? ? [] : text.split(",").map(&:strip)
                      elsif key == "concurrency"
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

          def configure(document)
            field(document, "netdisco", "source", "清单来源 http/postgres", "http")
            if document.dig("netdisco", "source") == "http"
              field(document, "netdisco", "url", "清单 URL", "https://netdisco.example.invalid")
            end
            %w[include_hosts exclude_hosts include_names exclude_names].each do |key|
              field(document, "inventory", key, key, [], list: true)
            end
            field(document, "inventory", "name_match", "名称匹配 contains/prefix/glob", "contains")
            %w[include_vendors exclude_vendors].each { |key| field(document, "inventory", key, key, [], list: true) }
            if document.key?("topology")
              field(document, "topology", "concurrency", "拓扑并发数 1..50", 4)
              field(document, "topology", "directory", "拓扑报告目录", "./topology_reports")
            else
              field(document, "backup", "concurrency", "并发数 1..50", 4)
              field(document, "backup", "directory", "备份目录", "./backups")
              field(document, "tftp", "server", "TFTP 服务器", "192.0.2.10")
            end
          end

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
