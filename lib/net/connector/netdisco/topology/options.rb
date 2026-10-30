# frozen_string_literal: true

require_relative "../../parallel/pool"
require_relative "../../device/interfaces/description"

module Net
  module Connector
    module Netdisco
      module Topology
        # 拓扑读取、格式化与输出策略；创建对象不授予 apply 权限。
        Options = Data.define(:mode, :cache_mode, :parallel, :directory, :description_format,
                                      :abbreviate_ports, :lowercase_ports, :limit, :neighbor_name_prefixes) do
          # 校验并固定拓扑执行模式、缓存、并发、目录及描述格式参数。
          def initialize(mode: :plan, cache_mode: :prefer, parallel: 4, directory: nil,
                         description_format: "To_%{neighbor}_%{port}", abbreviate_ports: true, lowercase_ports: false, limit: nil, neighbor_name_prefixes: [])
            unless (mode.is_a?(String) || mode.is_a?(Symbol)) && %w[plan discover apply].include?(mode.to_s)
              raise ArgumentError, "topology.mode must be plan, discover or apply"
            end
            unless (cache_mode.is_a?(String) || cache_mode.is_a?(Symbol)) && %w[prefer only refresh].include?(cache_mode.to_s)
              raise ArgumentError, "topology.cache_mode must be prefer, only or refresh"
            end
            Parallel::Pool.validate_parallel!(parallel)
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
            unless neighbor_name_prefixes.is_a?(Array) && neighbor_name_prefixes.all? do |prefix|
              prefix.is_a?(String) && prefix.match?(/\A[\p{Alnum}_.-]+\z/u)
            end
              raise ArgumentError, "topology.neighbor_name_prefixes must contain nonempty plain name prefixes"
            end
            super(mode: mode.to_sym, cache_mode: cache_mode.to_sym, parallel: parallel,
                  directory: directory&.dup&.freeze, description_format: description_format.dup.freeze,
                  abbreviate_ports: abbreviate_ports, lowercase_ports: lowercase_ports, limit: limit,
                  neighbor_name_prefixes: neighbor_name_prefixes.map { |prefix| prefix.dup.freeze }.freeze)
          end

          # 按受限占位模板组合邻居和端口名称，将空白转换为下划线。
          def format(neighbor:, port:)
            description_format % { neighbor: neighbor.to_s.gsub(/\s+/, "_"), port: port.to_s.gsub(/\s+/, "_") }
          end

          # 使用当前模板和端口展示策略生成缺失或确需修正的目标描述。
          def description_for(neighbor)
            port = neighbor.remote_interface
            port = Net::Connector::Interfaces::Name.short(port) if abbreviate_ports
            port = port.downcase if lowercase_ports
            format(neighbor: neighbor.remote_name, port: port)
          end

          # 仅显式声明的旧名称前缀可保留；不把未知名称、包含匹配或不同编号当作同一邻居。
          def description_matches?(current, expected, neighbor)
            comparison = Net::Connector::Interfaces::Description
            return true if comparison.equivalent?(current, expected)

            neighbor_name_prefixes.any? do |prefix|
              variant = neighbor.with(remote_name: prefix + neighbor.remote_name)
              comparison.equivalent?(current, description_for(variant))
            end
          end

          # 返回经校验的更新快照，未更新时沿用当前对象。
          def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
        end
      end
    end
  end
end
