# frozen_string_literal: true

require "digest"

module Net
  module Connector
    module Operations
      # 对同一 FD 做类型检查和读取；NOFOLLOW 只保护最后一个路径分量，目录由调用方保护。
      module SafeFile
        Fingerprint = Data.define(:path, :sha256, :mode, :dev, :ino)

        def self.open(path, missing: false, replace_symlink: false)
          file = open_handle(path, missing: missing, replace_symlink: replace_symlink)
          return nil unless file

          begin
            stat = file.stat
            raise ArgumentError, "saved configuration is not a regular file" unless stat.file?

            file.binmode
            yield file, stat
          ensure
            file.close
          end
        end

        def self.fingerprint(path, **options)
          self.open(path, **options) { |file, stat| fingerprint_io(path, file, stat) }
        end

        def self.fingerprint_io(path, file, stat)
          digest = Digest::SHA256.new
          while (chunk = file.read(64 * 1024))
            digest << chunk
          end
          Fingerprint.new(path: path.dup.freeze, sha256: digest.hexdigest.freeze,
                          mode: stat.mode & 0o7777, dev: stat.dev, ino: stat.ino)
        end

        # 未变内容可保留 mtime，但不能把已替换的目录项误认成刚读取的旧文件。
        def self.same_entry?(path, fingerprint)
          stat = File.lstat(path)
          stat.file? && stat.dev == fingerprint.dev && stat.ino == fingerprint.ino
        rescue Errno::ENOENT
          false
        end

        def self.open_handle(path, missing:, replace_symlink:)
          File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
        rescue Errno::ENOENT
          raise unless missing
        rescue Errno::ELOOP
          raise ArgumentError, "saved configuration is not a regular file", cause: nil unless replace_symlink
        rescue Errno::ENXIO
          raise ArgumentError, "saved configuration is not a regular file", cause: nil
        end

        private_class_method :open_handle
      end
    end
  end
end
