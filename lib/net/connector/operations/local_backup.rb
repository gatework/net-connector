# frozen_string_literal: true

require "digest"
require_relative "private_file"

module Net
  module Connector
    Backup = Data.define(:path, :bytes, :sha256, :collected_at, :change, :previous_sha256) do
      # 保存配置备份的路径、摘要和变更状态。
      def initialize(path:, bytes:, sha256:, collected_at:, change: nil, previous_sha256: nil)
        super
      end

      # 判断本次采集是否产生新的配置内容。
      def changed? = [:created, :changed].include?(change)
    end

    module Operations
      class LocalBackup
        # 保存执行配置采集的设备对象。
        def initialize(device) = @device = device

        # 采集配置、识别变更并原子写入私有文件。
        def call(path:)
          raise ArgumentError, "path must be a nonempty String" unless path.is_a?(String) && !path.empty?

          contents = @device.running_config.value!
          destination = File.expand_path(path)
          digest = Digest::SHA256.hexdigest(contents)
          previous_digest = Digest::SHA256.file(destination).hexdigest if File.file?(destination) && !File.symlink?(destination)
          change = if previous_digest.nil?
                     :created
                   elsif previous_digest == digest
                     :unchanged
                   else
                     :changed
                   end

          if change != :unchanged || (File.stat(destination).mode & 0o777) != 0o600
            PrivateFile.write(destination, contents)
          end
          Backup.new(path: destination, bytes: contents.bytesize,
                     sha256: digest, collected_at: Time.now.utc, change: change,
                     previous_sha256: previous_digest)
        end
      end
    end
  end
end
