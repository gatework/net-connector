# frozen_string_literal: true

require "digest"
require_relative "tftp/strategy"

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

        # 执行设备原生 TFTP 导出并核对完成回显。
        def call(host:, path: nil, source_file: nil, vrf: nil)
          strategy_class = @device.profile.tftp_strategy
          unless strategy_class
            raise UnsupportedOperation.new("native TFTP backup is not supported for this vendor",
                                           host: @device.host, phase: :tftp_backup)
          end
          strategy = strategy_class.new(@device)
          if vrf && (!vrf.is_a?(String) || !vrf.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/))
            raise ArgumentError, "vrf must be a single safe name"
          end
          # H3C 在解析源文件时可能连接设备，因此先验证调用方提供的目标。
          target = TftpTarget.new(host: host, path: path || "preflight.cfg", explicit_path: !path.nil?)
          source_file = strategy.source_file(source_file)
          target = TftpTarget.new(host: host, path: strategy.default_path(source_file), explicit_path: false) unless path
          result = @device.execute_operation(strategy.script(target, source_file: source_file, vrf: vrf),
                                             name: :tftp_backup, privilege: false)
          result.value!
          if transfer_failed?(result)
            @device.record_event("tftp_backup", level: :error, status: "transfer_failed", server: target.host)
            raise DeviceError.new("device reported TFTP backup failure",
                                  code: :transfer_failed, host: @device.host, phase: :tftp_backup)
          end
          unless strategy.complete?(result)
            @device.record_event("tftp_backup", level: :error, status: "transfer_unconfirmed", server: target.host)
            raise DeviceError.new("device did not confirm TFTP backup completion",
                                  code: :transfer_unconfirmed, host: @device.host, phase: :tftp_backup)
          end

          remote_path = strategy.remote_path(target, result)
          @device.record_event("tftp_backup", status: "reported_uploaded", server: target.host, path: remote_path)
          Net::Connector::TftpBackup.new(server: target.host, path: remote_path, completed_at: Time.now.utc)
        end

        private

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
