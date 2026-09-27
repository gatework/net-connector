# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require_relative "private_file"
require_relative "safe_file"
require_relative "saved_config/legacy_index"

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

        # 默认每次实时查找；批次显式 indexed 时共享一份惰性的旧命名文件快照。
        def initialize(directory:, indexed: false)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?
          raise ArgumentError, "indexed must be true or false" unless [true, false].include?(indexed)

          @directory = File.expand_path(directory).freeze
          @legacy_index = LegacyIndex.new(@directory) if indexed
        end

        # 优先查找固定文件名；仅在不存在时兼容唯一的旧命名文件。
        def find(host, required: true)
          with_file(host, required: required) { |path, _file, _stat| path }
        end

        # 比较基线也从经过 fstat 的同一 FD 读取，不在 find 后重新按路径打开。
        def fingerprint(host, required: true)
          with_file(host, required: required) { |path, file, stat| SafeFile.fingerprint_io(path, file, stat) }
        end

        def read(host)
          with_file(host) { |_path, file, _stat| file.read }
        end

        def resolve_path(host, required:)
          filename = self.class.filename(host)
          path = File.join(@directory, filename)
          unless File.exist?(path) || File.symlink?(path)
            entries = if @legacy_index
                        @legacy_index.candidates(filename)
                      else
                        Dir.children(@directory).select { |name| name.end_with?("-#{filename}") }
                      end
            return nil if entries.empty? && !required

            raise ArgumentError, "no saved configuration for #{host}" if entries.empty?
            raise ArgumentError, "multiple saved configurations for #{host}" if entries.size > 1

            path = @legacy_index ? entries.first : File.join(@directory, entries.first)
          end
          path
        end

        def with_file(host, required: true)
          path = resolve_path(host, required: required)
          return nil unless path
          return @legacy_index.open(path) { |name, file, stat| yield name, file, stat } if path.is_a?(LegacyIndex::Entry)

          SafeFile.open(path) { |file, stat| yield path, file, stat }
        end

        private :resolve_path, :with_file

        # 将已保存配置写入目标文件或标准输出。
        def export(host:, output: nil, io: $stdout)
          contents = read(host)
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
          require_relative "parse_output"

          parser = ParseOutput.new(template_dir: template_dir)
          parser.call(read(host), template: template, host: host)
        end
      end
    end
  end
end
