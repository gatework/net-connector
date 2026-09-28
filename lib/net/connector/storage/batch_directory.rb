# frozen_string_literal: true

require "fileutils"

module Net
  module Connector
    module Storage
      # 使用本地业务时区命名，原子创建互不覆盖的批次目录。
      class BatchDirectory
        # 固定 UTC+8，不依赖运行主机时区；mkdir 原子防止并发任务覆盖。
        def self.create(root, time: Time.now)
          FileUtils.mkdir_p(root, mode: 0o700)
          stamp = time.getlocal("+08:00").strftime("%Y-%m-%d_%H-%M-%S")
          suffix = 0
          loop do
            name = suffix.zero? ? stamp : "#{stamp}_#{format("%02d", suffix)}"
            path = File.join(root, name)
            begin
              Dir.mkdir(path, 0o700)
              return path
            rescue Errno::EEXIST
              suffix += 1
            end
          end
        end
      end
    end
  end
end
