# frozen_string_literal: true

require "textfsm"
require_relative "../engine/errors"
require_relative "../engine/terminal_renderer"

module Net
  module Connector
    module Operations
      # 将设备命令回显或配置文本按 TextFSM 模板转换为结构化记录。
      class ParseOutput
        DEFAULT_TEMPLATE_DIR = File.expand_path("../templates", __dir__).freeze

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
          raise ArgumentError, "text must be a String" unless text.is_a?(String)

          text = TerminalRenderer.render(text).force_encoding(Encoding::UTF_8)
          if template
            raise ArgumentError, "template must be a nonempty String" unless template.is_a?(String) && !template.empty?

            TextFSM::Parser.from_file(File.expand_path(template, @template_dir)).parse_hashes(text)
          else
            raise ArgumentError, "vendor and command are required for template lookup" unless vendor && command.is_a?(String) && !command.empty?

            attributes = { "Vendor" => vendor.to_s, "Command" => command }
            table = TextFSM::CliTable.new(index: @index, template_dir: @template_dir)
            unless table.index.match(attributes)
              raise ParsingError.new("no TextFSM template matches this vendor and command",
                                     code: :template_missing, host: host, phase: :parse)
            end
            table.parse(text, attributes: attributes).to_hashes
          end
        rescue TextFSM::IndexError
          raise ParsingError.new("TextFSM template index is invalid",
                                 code: :template_invalid, host: host, phase: :parse), cause: nil
        rescue TextFSM::TemplateError
          raise ParsingError.new("TextFSM template is invalid",
                                 code: :template_invalid, host: host, phase: :parse), cause: nil
        rescue TextFSM::ParseError
          raise ParsingError.new("TextFSM could not parse the device output",
                                 code: :parse_failed, host: host, phase: :parse), cause: nil
        rescue IOError, SystemCallError
          raise ParsingError.new("unable to read TextFSM template",
                                 code: :template_unreadable, host: host, phase: :parse), cause: nil
        end
      end
    end
  end
end
