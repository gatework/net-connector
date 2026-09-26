# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require_relative "private_file"
require_relative "parse_output"

module Net
  module Connector
    module Operations
      # 直接导出已有本地配置，无需访问 Netdisco。
      class SavedConfig
        # 只用规范化的管理地址标识配置，避免设备改名改变备份身份。
        def self.filename(host)
          raise ArgumentError, "host must be an IP address" unless host.is_a?(String) && !host.include?("/")

          "#{IPAddr.new(host).to_s.tr(":", "_")}.txt"
        rescue IPAddr::Error
          raise ArgumentError, "host must be an IP address"
        end

        # 保存已有配置文件所在目录。
        def initialize(directory:)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?

          @directory = File.expand_path(directory)
        end

        # 优先查找固定文件名；仅在不存在时兼容唯一的旧命名文件。
        def find(host, required: true)
          filename = self.class.filename(host)
          path = File.join(@directory, filename)
          unless File.exist?(path) || File.symlink?(path)
            entries = Dir.children(@directory).select { |name| name.end_with?("-#{filename}") }
            return nil if entries.empty? && !required

            raise ArgumentError, "no saved configuration for #{host}" if entries.empty?
            raise ArgumentError, "multiple saved configurations for #{host}" if entries.size > 1

            path = File.join(@directory, entries.first)
          end
          raise ArgumentError, "saved configuration is not a regular file" unless File.file?(path) && !File.symlink?(path)

          path
        end

        # 将已保存配置写入目标文件或标准输出。
        def export(host:, output: nil, io: $stdout)
          contents = File.binread(find(host))
          if output
            raise ArgumentError, "output must be a nonempty String" unless output.is_a?(String) && !output.empty?

            destination = File.expand_path(output)
            directory = File.dirname(destination)
            FileUtils.mkdir_p(directory, mode: 0o700)
            PrivateFile.write(destination, contents)
          else
            io.binmode if io.respond_to?(:binmode)
            io.write(contents)
            nil
          end
        end

        # 使用指定模板解析已有配置，无需访问设备或 Netdisco。
        def parse(host:, template:, template_dir: nil)
          parser = ParseOutput.new(template_dir: template_dir)
          parser.call(File.binread(find(host)), template: template, host: host)
        end
      end
    end
  end
end
