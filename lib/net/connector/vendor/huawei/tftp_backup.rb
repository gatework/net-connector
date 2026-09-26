# frozen_string_literal: true

require_relative "../../operations/tftp/file_upload"

module Net
  module Connector
    module Huawei
      class TftpBackup < Operations::Tftp::FileUpload
        # 要求调用方提供合法的华为启动配置文件路径。
        def source_file(value)
          raise ArgumentError, "Huawei TFTP backup requires source_file" unless value

          TftpTarget.validate_source_file!(value)
        end
      end
    end
  end
end
