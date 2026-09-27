# frozen_string_literal: true

require_relative "../../operations/tftp/file_upload"

module Net
  module Connector
    module Huawei
      class TftpBackup < Operations::Tftp::FileUpload
        # 缺少源文件也必须在首次设备 I/O 之前拒绝。
        def validate_options!(target, source_file:, vrf: nil)
          super
          raise ArgumentError, "Huawei TFTP backup requires source_file" if source_file.nil?
        end

        # 要求调用方提供合法的华为启动配置文件路径。
        def source_file(value)
          raise ArgumentError, "Huawei TFTP backup requires source_file" unless value

          TftpTarget.validate_source_file!(value)
        end
      end
    end
  end
end
