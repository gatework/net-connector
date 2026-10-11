# frozen_string_literal: true

require_relative "../../device/tftp/file_upload"

module Net
  module Connector
    module Huawei
      # 上传调用方明确指定的华为保存文件，连接前拒绝缺少源文件的请求。
      class TftpBackup < Tftp::FileUpload
        # 缺少源文件也必须在首次设备 I/O 之前拒绝。
        def validate_options!(target, source_file:, vrf: nil)
          super
          raise ArgumentError, "Huawei TFTP backup requires source_file" if source_file.nil?
        end

        # 读取调用方明确指定的合法保存文件路径，不根据文件名推断为启动配置。
        def resolve_source_file(value)
          raise ArgumentError, "Huawei TFTP backup requires source_file" unless value

          TftpTarget.validate_source_file!(value)
        end
      end
    end
  end
end
