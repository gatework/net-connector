# frozen_string_literal: true

require "digest"

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
  end
end
