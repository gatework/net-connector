# frozen_string_literal: true

require "fileutils"

module Net
  module Connector
    module Storage
      # 新建目录与已有目录的文件发布共用持久化边界。
      module Directory
        def self.prepare(path)
          path = File.expand_path(path)
          missing, parent = [], path
          until File.directory?(parent)
            missing << parent
            parent = File.dirname(parent)
          end
          FileUtils.mkdir_p(path, mode: 0o700)
          missing.reverse_each { |created| sync(File.dirname(created)) }
          path
        end

        def self.sync(path)
          File.open(File.realpath(path), File::RDONLY | File::NOFOLLOW) { |directory| directory.fsync }
        end
      end
    end
  end
end
