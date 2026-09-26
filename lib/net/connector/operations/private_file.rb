# frozen_string_literal: true

require "tempfile"

module Net
  module Connector
    module Operations
      # 将配置写入同目录的私有临时文件，再原子替换目标文件。
      module PrivateFile
        # 写入完整内容并同步到磁盘，避免覆盖失败留下半份配置。
        def self.write(path, contents)
          Tempfile.create([".net-connector-", ".tmp"], File.dirname(path)) do |file|
            file.binmode
            file.chmod(0o600)
            file.write(contents)
            file.flush
            file.fsync
            File.rename(file.path, path)
          end
          path
        end
      end
    end
  end
end
