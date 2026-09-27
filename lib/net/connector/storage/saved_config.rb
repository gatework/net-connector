# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require_relative "private_file"
require_relative "safe_file"

module Net
  module Connector
    module Storage
      # 直接导出已有本地配置，无需访问 Netdisco。
      class SavedConfig
        # 只用规范化的管理地址标识配置，避免设备改名改变备份身份。
        def self.filename(host)
          raise ArgumentError, "host must be an IP address" unless host.is_a?(String) && !host.include?("/")

          "#{IPAddr.new(host).to_s.tr(":", "_")}.txt"
        rescue IPAddr::Error
          raise ArgumentError, "host must be an IP address"
        end

        # 只读取规范设备地址对应的文件，不维护第二套历史文件命名。
        def initialize(directory:)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?

          @directory = File.expand_path(directory).freeze
        end

        # 从同一已验证文件描述符取得路径或内容。
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

        def with_file(host, required: true)
          path = File.join(@directory, self.class.filename(host))
          SafeFile.open(path, missing: !required) { |file, stat| yield path, file, stat }
        end

        private :with_file

        # 将已保存配置写入目标文件或标准输出。
        def export(host:, output: nil, io: $stdout)
          contents = read(host)
          if output
            raise ArgumentError, "output must be a nonempty String" unless output.is_a?(String) && !output.empty?

            destination = File.expand_path(output)
            directory = File.dirname(destination)
            FileUtils.mkdir_p(directory, mode: 0o700)
            PrivateFile.write(destination, contents).path
          else
            io.binmode if io.respond_to?(:binmode)
            io.write(contents)
            nil
          end
        end

        # 使用指定模板解析已有配置，无需访问设备或 Netdisco。
        def parse(host:, template:, template_dir: nil)
          require_relative "../textfsm"

          parser = TextFSM.new(template_dir: template_dir)
          parser.call(read(host), template: template, host: host)
        end
      end
    end
  end
end
