# frozen_string_literal: true

require_relative "../engine/errors"

module Net
  module Connector
    # 元数据采用组合，不改变 TftpBackup 的位置参数、成员或解构契约。
    class TftpReceipt
      KINDS = %i[running startup saved_file native_archive unknown].freeze
      FORMATS = %i[cfg xml dat tgz unknown].freeze
      private_constant :KINDS, :FORMATS

      attr_reader :transfer, :configuration_kind, :source_file, :format, :requested_path, :actual_path,
                  :verification, :server_sha256

      def initialize(transfer:, configuration_kind: :unknown, source_file: nil, format: :unknown,
                     requested_path: nil, actual_path:, verification: :device_reported, server_sha256: nil)
        unless transfer.instance_of?(TftpBackup) && transfer.completed_at.is_a?(Time) && transfer.path == actual_path
          raise ArgumentError, "TFTP receipt requires a matching transfer"
        end
        TftpTarget.new(host: transfer.server, path: actual_path.nil? ? "unconfirmed" : actual_path)
        TftpTarget.validate_path!(requested_path) unless requested_path.nil?
        TftpTarget.validate_source_file!(source_file) unless source_file.nil?
        unless KINDS.include?(configuration_kind) && FORMATS.include?(format)
          raise ArgumentError, "invalid TFTP configuration kind or format"
        end
        valid_verification = (verification == :device_reported && server_sha256.nil?) ||
          (verification == :server_verified && !actual_path.nil? && server_sha256.is_a?(String) &&
            server_sha256.match?(/\A[0-9a-f]{64}\z/))
        raise ArgumentError, "invalid TFTP verification evidence" unless valid_verification

        @actual_path, @requested_path = actual_path&.dup&.freeze, requested_path&.dup&.freeze
        @source_file, @server_sha256 = source_file&.dup&.freeze, server_sha256&.dup&.freeze
        @configuration_kind, @format, @verification = configuration_kind, format, verification
        @transfer = transfer.with(server: transfer.server.dup.freeze, path: @actual_path,
                                  completed_at: transfer.completed_at.dup.freeze)
        freeze
      end

      # 摘要不展开设备输出或调用方的源文件名。
      def inspect = "#<#{self.class} kind=#{configuration_kind} format=#{format} verification=#{verification}>"
    end

    # 上传已确认后的失败不能被解释为“尚未上传”，也不能携带原始诊断正文。
    class TftpCompletionError < Error
      MESSAGES = {
        transfer_finalize_failed: "device reported TFTP completion but finalization failed",
        transfer_path_unconfirmed: "device reported TFTP completion but its remote path is unconfirmed",
        transfer_path_mismatch: "device reported TFTP completion at a different remote path"
      }.freeze
      private_constant :MESSAGES

      attr_reader :receipt, :underlying_type

      def initialize(receipt:, code: :transfer_finalize_failed, host: nil, underlying: nil)
        unless receipt.instance_of?(TftpReceipt) && MESSAGES.key?(code)
          raise ArgumentError, "TFTP completion error requires a transfer receipt and a known failure code"
        end

        @receipt = receipt
        type = if underlying.is_a?(Error) && underlying.underlying.instance_of?(UnderlyingError)
                 underlying.underlying.type
               else
                 underlying&.class&.name
               end
        @underlying_type = type&.match?(/\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/) && type.bytesize <= 128 ? type.freeze : nil
        super(MESSAGES.fetch(code), code: code, host: host, phase: :tftp_backup)
      end

      def transfer = receipt.transfer
    end
  end
end
