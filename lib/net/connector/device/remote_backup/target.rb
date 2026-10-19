# frozen_string_literal: true

module Net
  module Connector
    class RemoteBackup
      # 目标必须可直接作为一个 CLI 单词使用，不接受 URL 内密码或命令片段。
      Target = Data.define(:host, :path, :username, :protocol) do
        # 校验并固定远端备份的服务器、路径、用户名和协议。
        def initialize(host:, path:, username:, protocol:)
          unless %i[ftp scp].include?(protocol)
            raise ArgumentError, "remote backup protocol must be ftp or scp"
          end
          unless username.is_a?(String) && username.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/)
            raise ArgumentError, "remote backup username must be a safe account name"
          end
          unless host.is_a?(String) && host.bytesize <= 253 && host.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/) && !host.include?("..")
            raise ArgumentError, "remote backup host must be an IPv4 address or DNS name"
          end
          unless path.is_a?(String) && path.bytesize <= 220 &&
                 path.match?(/\A[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\z/) &&
                 path.split("/").none? { |part| %w[. ..].include?(part) }
            raise ArgumentError, "remote backup path must be a relative filename without traversal"
          end
          super(host: host.dup.freeze, path: path.dup.freeze, username: username.dup.freeze, protocol: protocol)
        end

        # Ruby 3.2 的原生更新跳过构造校验；更新也必须建立经过校验的快照。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        # 构造不含密码的上传 URL，分别编码用户名与目标路径。
        def url
          "#{protocol}://#{username}@#{host}/#{path}"
        end
      end
      private_constant :Target
    end
  end
end
