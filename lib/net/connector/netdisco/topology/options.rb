# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      module Topology
        # 拓扑读取、格式化与输出策略；创建对象不授予 apply 权限。
        Options = Data.define(:mode, :cache_mode, :concurrency, :directory, :description_format,
                                      :abbreviate_ports, :lowercase_ports, :limit) do
          def initialize(mode: :plan, cache_mode: :prefer, concurrency: 4, directory: nil,
                         description_format: "To_%{neighbor}_%{port}", abbreviate_ports: true, lowercase_ports: false, limit: nil)
            unless (mode.is_a?(String) || mode.is_a?(Symbol)) && %w[plan discover apply].include?(mode.to_s)
              raise ArgumentError, "topology.mode must be plan, discover or apply"
            end
            unless (cache_mode.is_a?(String) || cache_mode.is_a?(Symbol)) && %w[prefer only refresh].include?(cache_mode.to_s)
              raise ArgumentError, "topology.cache_mode must be prefer, only or refresh"
            end
            unless concurrency.is_a?(Integer) && (1..50).cover?(concurrency)
              raise ArgumentError, "topology.concurrency must be in 1..50"
            end
            unless limit.nil? || (limit.is_a?(Integer) && limit.positive?)
              raise ArgumentError, "topology.limit must be a positive integer or nil"
            end
            unless [true, false].include?(abbreviate_ports) && [true, false].include?(lowercase_ports)
              raise ArgumentError, "topology port options must be booleans"
            end
            unless directory.nil? || (directory.is_a?(String) && !directory.empty? && !directory.match?(/[\r\n\0]/))
              raise ArgumentError, "topology.directory must be a literal directory path"
            end
            unless description_format.is_a?(String) && !description_format.empty? &&
                   !description_format.match?(/[\r\n\0]/) && !description_format.gsub(/%\{(?:neighbor|port)\}/, "").include?("%")
              raise ArgumentError, "topology.description_format accepts only %{neighbor} and %{port} placeholders"
            end
            super(mode: mode.to_sym, cache_mode: cache_mode.to_sym, concurrency: concurrency,
                  directory: directory&.dup&.freeze, description_format: description_format.dup.freeze,
                  abbreviate_ports: abbreviate_ports, lowercase_ports: lowercase_ports, limit: limit)
          end

          def format(neighbor:, port:)
            description_format % { neighbor: neighbor.to_s.gsub(/\s+/, "_"), port: port.to_s.gsub(/\s+/, "_") }
          end

          def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
        end
      end
    end
  end
end
