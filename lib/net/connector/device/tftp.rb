# frozen_string_literal: true

require_relative "tftp/strategy"
require_relative "tftp/receipt"

module Net
  module Connector
    class Tftp
      # 设备入口与功能实现共置，Base 只组合能力，不重复业务流程。
      module Capability
        # 要求设备直接向 TFTP 服务器导出原生配置。
        # 完成仅表示设备报告传输成功，未读取服务器端文件。
        def tftp_backup(host:, path: nil, source_file: nil, vrf: nil)
          Tftp.new(self).call(host: host, path: path, source_file: source_file, vrf: vrf)
        end
      end

      # 保存执行 TFTP 导出的设备对象。
      def initialize(device) = @device = device

      # 参数先纯校验；源探测、上传、证据核对及收尾共用一次会话租约。
      def call(host:, path: nil, source_file: nil, vrf: nil)
        receipt = nil
        strategy_class = @device.profile.tftp_strategy
        unless strategy_class
          raise UnsupportedOperation.new("native TFTP backup is not supported for this vendor",
                                         host: @device.host, phase: :tftp_backup)
        end
        strategy = strategy_class.new(@device)
        if !vrf.nil? && (!vrf.is_a?(String) || !vrf.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/))
          raise ArgumentError, "vrf must be a single safe name"
        end
        source_file = TftpTarget.validate_source_file!(source_file).dup.freeze unless source_file.nil?
        vrf = vrf&.dup&.freeze
        target = TftpTarget.new(host: host, path: path.nil? ? "preflight.cfg" : path, explicit_path: !path.nil?)
        strategy.validate_options!(target, source_file: source_file, vrf: vrf)
        @device.with_operation(:tftp_backup) do
          source = strategy.resolve_source_file(source_file)
          source = TftpTarget.validate_source_file!(source).dup.freeze unless source.nil?
          target = TftpTarget.new(host: target.host, path: strategy.default_path(source), explicit_path: false) if path.nil?
          result = @device.execute_operation(strategy.script(target, source_file: source, vrf: vrf),
                                             name: :tftp_backup, privilege: false)
          confirm_transfer!(strategy, target, result)
          # 一旦看到明确完成证据就保存回执；路径解析或用户钩子失败也不能抹去上传事实。
          requested_path = target.explicit_path? ? target.path : nil
          receipt = TftpReceipt.new(server: target.host, path: nil, completed_at: Time.now.utc,
                                    requested_path: requested_path, source_file: source)
          actual_path = remote_path(strategy, target, result, receipt)
          receipt = receipt.with(path: actual_path)
          receipt = build_receipt(strategy, target, source, !source_file.nil?, receipt)
          if target.explicit_path? && target.path != receipt.path
            raise TftpCompletionError.new(receipt: receipt, code: :transfer_path_mismatch, host: @device.host), cause: nil
          end
          # 已完成步骤仍可能伴随后处理/清理错误；上面的回执要先构造，再重新抛出。
          result.value! if result.failure?
          @device.log_event("tftp_backup", status: "reported_uploaded", phase: :tftp_backup,
                                server: target.host, path: receipt.path)
          receipt
        end
      rescue StandardError => error
        raise unless receipt
        raise if error.instance_of?(TftpCompletionError) && error.receipt.equal?(receipt)

        raise TftpCompletionError.new(receipt: receipt, host: @device.host, underlying: error), cause: nil
      end

      private

      def build_receipt(strategy, target, source_file, explicit_source, receipt)
        metadata = strategy.receipt_metadata(target, source_file: source_file, explicit_source: explicit_source)
        unless metadata.is_a?(Hash) && (metadata.keys - %i[configuration_kind source_file format requested_path]).empty?
          raise ArgumentError, "invalid TFTP strategy receipt metadata"
        end
        receipt.with(**{ source_file: source_file, requested_path: target.path }.merge(metadata))
      end

      def remote_path(strategy, target, result, receipt)
        TftpTarget.validate_path!(strategy.remote_path(target, result))
      rescue StandardError => error
        raise TftpCompletionError.new(receipt: receipt, code: :transfer_path_unconfirmed,
                                       host: @device.host, underlying: error), cause: nil
      end

      # 失败证据优先；步骤中的明确完成行可在随后清理失败时证明设备已经报告上传。
      def confirm_transfer!(strategy, target, result)
        if transfer_failed?(result)
          @device.log_event("tftp_backup", level: :error, status: "transfer_failed", phase: :tftp_backup,
                                code: :transfer_failed, server: target.host)
          raise DeviceError.new("device reported TFTP backup failure",
                                code: :transfer_failed, host: @device.host, phase: :tftp_backup)
        end
        return if strategy.device_reported_complete?(result)

        result.value! if result.failure?
        @device.log_event("tftp_backup", level: :error, status: "transfer_unconfirmed", phase: :tftp_backup,
                              code: :transfer_unconfirmed, server: target.host)
        raise DeviceError.new("device did not confirm TFTP backup completion",
                              code: :transfer_unconfirmed, host: @device.host, phase: :tftp_backup)
      end

      # 识别设备回显中的传输失败信息。
      def transfer_failed?(result)
        result.steps.any? do |step|
          # 文件名中的 failed.cfg、error-backup 等不属于诊断词；句末标点仍是词边界。
          pattern = %r{(?<![\w./-])
            (?:error|failed|failure|aborted|denied|timed\ out|timeout|not\ found|no\ such\ file|
               unable\ to|network\ is\ unreachable|can't\ open)
            (?![\w/-]|\.[\w])}ix
          # 原始诊断不能被回车抹除，颜色控制符也不能掩盖失败词。
          history = step.output.gsub(/\r(?!\n)/, "\n")
          step.output.match?(pattern) || TerminalRenderer.render(history).match?(pattern) ||
            TerminalRenderer.render(step.output).match?(pattern)
        end
      end
    end
  end
end
