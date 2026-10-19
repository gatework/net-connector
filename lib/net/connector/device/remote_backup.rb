# frozen_string_literal: true

require_relative "../engine/script"
require_relative "remote_backup/receipt"

module Net
  module Connector
    # 设备原生 FTP/SCP 导出；与采集到本机的 LocalBackup 分别保留完成证据。
    class RemoteBackup
      module Capability
        # 让设备向指定服务器导出备份，交互密码只用于当前上传。
        def remote_backup(host:, path:, username:, protocol: :scp, password: nil)
          RemoteBackup.new(self).call(host: host, path: path, username: username, protocol: protocol, password: password)
        end
      end

      # 保存执行远端备份的设备对象。
      def initialize(device) = @device = device

      # 在一次设备操作中执行导出，完成后先保留回执，再处理收尾错误。
      def call(host:, path:, username:, protocol:, password: nil)
        receipt = nil
        implementation = @device.profile.remote_backup_strategy
        unless implementation
          raise UnsupportedOperation.new("native FTP/SCP backup is not supported for this vendor",
                                         host: @device.host, phase: :remote_backup)
        end
        target = Target.new(host: host, path: path, username: username, protocol: protocol)
        if !password.nil? && (!password.is_a?(String) || password.match?(/[\r\n\x00]/))
          raise ArgumentError, "remote backup password must be a single-line String"
        end
        password = password&.dup&.freeze
        strategy = implementation.new(@device)
        @device.with_operation(:remote_backup) do
          result = @device.execute_operation(strategy.script(target, password: password), name: :remote_backup, privilege: false)
          unless strategy.completed?(target, result)
            result.value!
            raise DeviceError.new("device did not confirm remote backup completion", code: :transfer_unconfirmed,
                                  host: @device.host, phase: :remote_backup)
          end
          receipt = Receipt.new(server: target.host, path: target.path, protocol: target.protocol, username: target.username,
                      completed_at: Time.now.utc)
          result.value! if result.failure?
          receipt
        end
      rescue StandardError => error
        raise unless receipt
        raise if error.instance_of?(CompletionError)

        raise CompletionError.new(receipt: receipt, host: @device.host, underlying: error), cause: nil
      end
    end
  end
end
