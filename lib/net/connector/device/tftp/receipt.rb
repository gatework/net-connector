# frozen_string_literal: true

require_relative "../../engine/errors"
require_relative "target"

module Net
  module Connector
    # 一次设备上报上传的不可变回执；path 是实际目标，未知时保持 nil。
    TftpReceipt = Data.define(:server, :path, :completed_at, :configuration_kind, :source_file,
                             :format, :requested_path, :verification, :server_sha256)

    class TftpReceipt
      KINDS = %i[running startup saved_file native_archive unknown].freeze
      FORMATS = %i[cfg xml dat tgz unknown].freeze
      private_constant :KINDS, :FORMATS

      def initialize(server:, path:, completed_at:, configuration_kind: :unknown, source_file: nil,
                     format: :unknown, requested_path: nil, verification: :device_reported, server_sha256: nil)
        raise ArgumentError, "completed_at must be a Time" unless completed_at.is_a?(Time)

        TftpTarget.new(host: server, path: path.nil? ? "unconfirmed" : path)
        TftpTarget.validate_path!(requested_path) unless requested_path.nil?
        TftpTarget.validate_source_file!(source_file) unless source_file.nil?
        unless KINDS.include?(configuration_kind) && FORMATS.include?(format)
          raise ArgumentError, "invalid TFTP configuration kind or format"
        end
        valid_verification = (verification == :device_reported && server_sha256.nil?) ||
          (verification == :server_verified && !path.nil? && server_sha256.is_a?(String) &&
            server_sha256.match?(/\A[0-9a-f]{64}\z/))
        raise ArgumentError, "invalid TFTP verification evidence" unless valid_verification

        super(server: server.dup.freeze, path: path&.dup&.freeze, completed_at: completed_at.dup.freeze,
              configuration_kind: configuration_kind, source_file: source_file&.dup&.freeze, format: format,
              requested_path: requested_path&.dup&.freeze, verification: verification,
              server_sha256: server_sha256&.dup&.freeze)
      end

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
    end
  end
end
