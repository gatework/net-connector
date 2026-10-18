# frozen_string_literal: true

module Net
  module Connector
    class Topology
      # interface 块方言共用完整性校验；解析器不能静默遗漏未知接口头。
      module InterfaceBlocks
        def validate_descriptions!(config, rows)
          expected = config.scan(/^interface[ \t]+([^\r\n]*)/).flatten.map(&:strip)
          return if expected == rows.map { |row| row.fetch("INTERFACE").strip }

          raise ParsingError.new("interface description output was not fully recognized", code: :unrecognized_output,
                                 host: @device.host, phase: :verify)
        end
      end
    end
  end
end
