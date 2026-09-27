# frozen_string_literal: true

require "digest"
require_relative "tftp/strategy"
require_relative "tftp_receipt"

module Net
  module Connector
    # 设备主动上传使用的 TFTP 目标，服务器必须能被设备访问。
    class TftpTarget
      MAX_PATH_BYTES = 220

      attr_reader :host, :path

      # 校验并保存 TFTP 服务器、远端路径及显式文件名标记。
      def initialize(host:, path:, explicit_path: true)
        unless host.is_a?(String) && host.bytesize <= 253 &&
               host.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/) && !host.include?("..")
          raise ArgumentError, "TFTP host must be an IPv4 address or DNS name"
        end
        self.class.validate_path!(path)
        @host, @path = host.dup.freeze, path.dup.freeze
        @explicit_path = explicit_path
        freeze
      end

      # 判断调用方是否明确指定了远端文件名。
      def explicit_path? = @explicit_path

      # 校验设备或调用方给出的远端相对路径。
      def self.validate_path!(path)
        unless path.is_a?(String) && path.bytesize <= MAX_PATH_BYTES &&
               path.match?(/\A[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\z/) &&
               path.split("/").none? { |part| %w[. ..].include?(part) }
          raise ArgumentError, "TFTP path must be a relative filename or path without traversal"
        end
        path
      end

      # 设备地址和可选清单名称共用目标长度限制；极长地址用稳定摘要表示。
      def self.filename(host, extension:, label: nil)
        if label && (!label.is_a?(String) || !label.ascii_only?)
          raise ArgumentError, "TFTP label must be an ASCII String"
        end

        address = host.gsub(/[^A-Za-z0-9._-]/, "_")
        suffix = "#{address}.#{extension}"
        if suffix.bytesize > MAX_PATH_BYTES - (label ? 2 : 0)
          suffix = "#{Digest::SHA256.hexdigest(host)}.#{extension}"
        end
        path = label ? "#{label.byteslice(0, MAX_PATH_BYTES - suffix.bytesize - 1)}-#{suffix}" : suffix
        validate_path!(path)
      end

      # 校验设备源文件路径是否符合命令安全约束。
      def self.validate_source_file!(value)
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9._:\/-]+\z/) &&
               !value.split("/").include?("..")
          raise ArgumentError, "source_file must be a device file path without spaces or traversal"
        end
        value
      end
    end

    TftpBackup = Data.define(:server, :path, :completed_at)

    module Operations
      class TftpBackup
        # 保存执行 TFTP 导出的设备对象。
        def initialize(device) = @device = device

        # 保留原有返回结构；扩展元数据由 call_receipt 单独提供。
        def call(host:, path: nil, source_file: nil, vrf: nil)
          call_receipt(host: host, path: path, source_file: source_file, vrf: vrf).transfer
        end

        # 参数先纯校验；源探测、上传、证据核对及收尾共用一次会话租约。
        def call_receipt(host:, path: nil, source_file: nil, vrf: nil)
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
          if strategy_hook?(strategy, :validate_options!)
            strategy.validate_options!(target, source_file: source_file, vrf: vrf)
          end
          @device.with_operation(:tftp_backup) do
            source = strategy.source_file(source_file)
            source = TftpTarget.validate_source_file!(source).dup.freeze unless source.nil?
            target = TftpTarget.new(host: target.host, path: strategy.default_path(source), explicit_path: false) if path.nil?
            result = @device.execute_operation(strategy.script(target, source_file: source, vrf: vrf),
                                               name: :tftp_backup, privilege: false)
            confirm_transfer!(strategy, target, result)
            # 一旦看到明确完成证据就保存回执；路径解析或用户钩子失败也不能抹去上传事实。
            transfer = Net::Connector::TftpBackup.new(server: target.host, path: nil, completed_at: Time.now.utc)
            requested_path = target.explicit_path? ? target.path : nil
            receipt = TftpReceipt.new(transfer: transfer, actual_path: nil, requested_path: requested_path, source_file: source)
            actual_path = remote_path(strategy, target, result, receipt)
            receipt = TftpReceipt.new(transfer: transfer.with(path: actual_path), actual_path: actual_path,
                                      requested_path: requested_path, source_file: source)
            receipt = receipt_metadata(strategy, target, source, !source_file.nil?, receipt)
            if target.explicit_path? && target.path != receipt.actual_path
              raise TftpCompletionError.new(receipt: receipt, code: :transfer_path_mismatch, host: @device.host), cause: nil
            end
            # 已完成步骤仍可能伴随后处理/清理错误；上面的回执要先构造，再重新抛出。
            result.value! if result.failure?
            @device.record_event("tftp_backup", status: "reported_uploaded", server: target.host, path: receipt.actual_path)
            receipt
          end
        rescue StandardError => error
          raise unless receipt
          raise if error.instance_of?(TftpCompletionError) && error.receipt.equal?(receipt)

          raise TftpCompletionError.new(receipt: receipt, host: @device.host, underlying: error), cause: nil
        end

        private

        # 旧扩展若重写 script，不继承父厂商新增的参数限制或配置来源声明。
        # 同时重写相应钩子才表示扩展已为自己的脚本实现这项契约。
        def strategy_hook?(strategy, name)
          strategy.respond_to?(name) && !!(strategy.method(name).owner <= strategy.method(:script).owner)
        end

        def receipt_metadata(strategy, target, source_file, explicit_source, receipt)
          return receipt unless strategy_hook?(strategy, :receipt_metadata)

          metadata = strategy.receipt_metadata(target, source_file: source_file, explicit_source: explicit_source)
          unless metadata.is_a?(Hash) && (metadata.keys - %i[configuration_kind source_file format requested_path]).empty?
            raise ArgumentError, "invalid TFTP strategy receipt metadata"
          end
          TftpReceipt.new(transfer: receipt.transfer, actual_path: receipt.actual_path,
                          **{ source_file: source_file, requested_path: target.path }.merge(metadata))
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
            @device.record_event("tftp_backup", level: :error, status: "transfer_failed", server: target.host)
            raise DeviceError.new("device reported TFTP backup failure",
                                  code: :transfer_failed, host: @device.host, phase: :tftp_backup)
          end
          unless strategy.complete?(result)
            result.value! if result.failure?
            @device.record_event("tftp_backup", level: :error, status: "transfer_unconfirmed", server: target.host)
            raise DeviceError.new("device did not confirm TFTP backup completion",
                                  code: :transfer_unconfirmed, host: @device.host, phase: :tftp_backup)
          end
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
end
