# frozen_string_literal: true

require_relative "../config"

module Net
  module Connector
    module Netdisco
      module Config
        # 三个入口共用的初始策略；只接收允许列表内的公开设置，凭据不进入 YAML。
        module Defaults
          # 合并保守默认值、已识别环境和本次参数；拓扑初始化始终采用只读规划。
          def self.document(mode:, values:, directory: nil)
            document = {
              "netdisco" => { "source" => "http", "cache_enabled" => true, "cache_mode" => "prefer", "cache_ttl" => 259_200,
                              "cache_directory" => "./.cache/net-connector/inventory", "inventory_timeout" => 300,
                              "page_size" => 500, "allow_insecure_http" => false },
              "inventory" => { "include_hosts" => [], "exclude_hosts" => [], "include_names" => [], "exclude_names" => [],
                               "include_vendors" => [], "exclude_vendors" => [], "name_match" => "contains",
                               "include_models" => [], "exclude_models" => [], "model_match" => "contains" },
              "ssh" => { "protocol" => "ssh", "host_key_policy" => "accept_new", "log_level" => "info" },
              "backup" => { "directory" => directory || "./backups", "parallel" => 4 }
            }
            seed(document, values)
            if mode == :topology
              topology = { "cache_mode" => document.fetch("netdisco").fetch("cache_mode"),
                           "parallel" => document.fetch("backup").fetch("parallel"), "directory" => directory || "./topologys",
                           "description_format" => "To_%{neighbor}_%{port}", "abbreviate_ports" => true,
                           "lowercase_ports" => false, "neighbor_name_prefixes" => [] }
              document["topology"] = topology.merge(document.fetch("topology", {})).merge("mode" => "plan")
              document["topology"]["directory"] = values["NC_BACKUP_DIRECTORY"] if values["NC_BACKUP_DIRECTORY"] && !values["NC_TOPOLOGY_DIRECTORY"]
              document.delete("backup")
            end
            document["tftp"] ||= {} if mode == :tftp
            document
          end

          # 根据字段声明转换环境文本；错误只报告变量名，避免回显其内容。
          def self.decode(key, type, value)
            case type
            when :integer, :optional_integer then Integer(value, 10)
            when :number then Float(value)
            when :boolean
              raise ArgumentError unless %w[true false].include?(value)

              value == "true"
            when :list then value.split(",", -1).map(&:strip)
            when :json, :json_array then JSON.parse(value)
            else value
            end
          rescue ArgumentError, TypeError, JSON::ParserError
            raise ArgumentError, "初始化参数 #{key} 格式无效", cause: nil
          end

          # 同一字段声明同时约束加载与生成，不持久化密码或未知环境变量。
          def self.seed(document, values)
            FIELDS.each do |section, fields|
              fields.each do |name, (key, type)|
                value = values[key]
                next if value.nil? || value.empty?

                (document[section] ||= {})[name] = decode(key, type, value)
              end
            end
          end
        end
      end
    end
  end
end
