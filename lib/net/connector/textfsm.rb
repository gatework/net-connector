# frozen_string_literal: true

require_relative "engine/errors"
require_relative "engine/terminal_text"

module Net
  module Connector
    # 将设备命令回显或配置文本按 TextFSM 模板转换为结构化记录。
    class TextFSM
      # 设备入口与功能实现共置，Base 只组合能力，不重复业务流程。
      module Capability
        # 执行命令并按厂商、命令或显式 TextFSM 模板返回结构化记录。
        def parse_command(command, template: nil, template_dir: nil)
          parser = TextFSM.new(template_dir: template_dir)
          parser.call(execute_command(command).value!, template: template, vendor: vendor, command: command, host: host)
        end

        # 采集运行配置并使用指定 TextFSM 模板提取结构化记录。
        def parse_config(template:, template_dir: nil)
          parser = TextFSM.new(template_dir: template_dir)
          parser.call(running_config.value!, template: template, host: host)
        end
      end

      DEFAULT_TEMPLATE_DIR = File.expand_path("templates", __dir__).freeze

      # 配置模板目录和 Netmiko 风格的命令索引文件。
      def initialize(template_dir: nil, index: "index")
        template_dir ||= DEFAULT_TEMPLATE_DIR
        raise ArgumentError, "template_dir must be a nonempty String" unless template_dir.is_a?(String) && !template_dir.empty?
        raise ArgumentError, "index must be a nonempty String" unless index.is_a?(String) && !index.empty?

        @template_dir = File.expand_path(template_dir)
        @index = index
      end

      # 显式模板按路径读取；未指定时按厂商和命令从索引选择模板。
      def call(text, template: nil, vendor: nil, command: nil, host: nil)
        require "textfsm"

        text = TerminalText.render(text, host: host)
        if template
          raise ArgumentError, "template must be a nonempty String" unless template.is_a?(String) && !template.empty?

          ::TextFSM::Parser.from_file(File.expand_path(template, @template_dir)).parse_hashes(text)
        else
          raise ArgumentError, "vendor and command are required for template lookup" unless vendor && command.is_a?(String) && !command.empty?

          attributes = { "Vendor" => vendor.to_s, "Command" => command }
          table = ::TextFSM::CliTable.new(index: @index, template_dir: @template_dir)
          unless table.index.match(attributes)
            raise ParsingError.new("no TextFSM template matches this vendor and command",
                                   code: :template_missing, host: host, phase: :parse)
          end
          table.parse(text, attributes: attributes).to_hashes
        end
      rescue ::TextFSM::IndexError
        raise ParsingError.new("TextFSM template index is invalid",
                               code: :template_invalid, host: host, phase: :parse), cause: nil
      rescue ::TextFSM::TemplateError
        raise ParsingError.new("TextFSM template is invalid",
                               code: :template_invalid, host: host, phase: :parse), cause: nil
      rescue ::TextFSM::ParseError
        raise ParsingError.new("TextFSM could not parse the device output",
                               code: :parse_failed, host: host, phase: :parse), cause: nil
      rescue IOError, SystemCallError
        raise ParsingError.new("unable to read TextFSM template",
                               code: :template_unreadable, host: host, phase: :parse), cause: nil
      end
    end
  end
end
