# frozen_string_literal: true

require "uri"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 区分本地目录与 SSH 归档端点；远端 URI 只携带路径和用户名，不含密码。
        module Root
          # 路径百分号编解码固定使用同一规则，不依赖 URI 默认解析器的版本变化。
          PATH_PARSER = URI::RFC2396_Parser.new.freeze
          UNSAFE_PATH = /[^A-Za-z0-9\-._~!$&'()*+,;=:@\/]/.freeze
          private_constant :PATH_PARSER, :UNSAFE_PATH

          # 判断根目录是否声明为 SSH 远端归档端点。
          def self.remote?(value) = value.is_a?(String) && value.start_with?("ssh://")

          # 校验并解析无密码 SSH 端点，拒绝凭据嵌入路径或命令参数。
          def self.endpoint(value)
            uri = URI.parse(value)
            path = PATH_PARSER.unescape(uri.path.to_s)
            unless uri.scheme == "ssh" && uri.host&.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/) &&
                   uri.user&.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/) && !uri.password &&
                   !uri.query && !uri.fragment && (uri.port.nil? || (1..65_535).cover?(uri.port)) &&
                   path.start_with?("/") && !path.match?(/[\r\n\0]/) && (path.split("/") & %w[. ..]).empty?
              raise ArgumentError, "SSH TFTP root requires ssh://user@host/absolute/path without a password"
            end
            [uri, path]
          rescue URI::InvalidURIError
            raise ArgumentError, "invalid SSH TFTP root", cause: nil
          end

          # 保留路径分隔与合法字符，转义查询、片段和百分号，避免服务器文件名改变 URI 结构。
          def self.encode_path(path) = PATH_PARSER.escape(path, UNSAFE_PATH)

          # SSH 根目录先校验再保留原值，本地路径交给调用方解析。
          def self.resolve(value)
            return yield(value) unless remote?(value)

            endpoint(value)
            value.dup.freeze
          end
        end
      end
    end
  end
end
