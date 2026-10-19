# frozen_string_literal: true

require_relative "target"
require_relative "../../engine/errors"

module Net
  module Connector
    class RemoteBackup
      # 不保存认证秘密；此回执只说明设备报告写出，未读取远端文件。
      Receipt = Data.define(:server, :path, :protocol, :username, :completed_at, :configuration_kind, :verification) do
        # 复制并冻结设备报告的远端备份元数据，不将回执当作服务器核验。
        def initialize(server:, path:, protocol:, username:, completed_at:, configuration_kind: :running, verification: :device_reported)
          Target.new(host: server, path: path, protocol: protocol, username: username)
          unless completed_at.is_a?(Time) && configuration_kind == :running && verification == :device_reported
            raise ArgumentError, "invalid remote backup receipt"
          end
          super(server: server.dup.freeze, path: path.dup.freeze, protocol: protocol, username: username.dup.freeze,
                completed_at: completed_at.dup.freeze, configuration_kind: configuration_kind, verification: verification)
        end

        # Ruby 3.2 的原生更新跳过构造校验；更新也必须建立经过校验的快照。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

      end

      # 完成后出现收尾错误时保留上传事实，避免调用方盲目重传。
      class CompletionError < Error
        # 读取远端上传回执及随后收尾故障的受控类型。
        attr_reader :receipt, :underlying_type

        # 保留已报告完成的远端回执，并登记随后收尾失败的受控诊断。
        def initialize(receipt:, host:, underlying:)
          raise ArgumentError, "remote backup receipt required" unless receipt.instance_of?(Receipt)

          @receipt = receipt
          @underlying_type = Error::Metadata.type(underlying.class.name)
          super("device reported remote backup completion but finalization failed",
                code: :transfer_finalize_failed, host: host, phase: :remote_backup)
        end
      end
    end
  end
end
