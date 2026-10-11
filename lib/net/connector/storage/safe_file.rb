# frozen_string_literal: true

require "digest"

module Net
  module Connector
    module Storage
      # 对同一 FD 做类型检查和读取；NOFOLLOW 只保护最后一个路径分量，目录由调用方保护。
      module SafeFile
        Fingerprint = Data.define(:path, :sha256, :mode, :dev, :ino)

        def self.open(path, missing: false, replace_symlink: false)
          file = acquisition_error = nil
          begin
            # 取得描述符与登记所有权共用短暂边界；读取和业务块仍可中断。
            Thread.handle_interrupt(Exception => :never) do
              begin
                file = open_handle(path, missing: missing, replace_symlink: replace_symlink)
              rescue Exception => error # rubocop:disable Lint/RescueException -- 取得失败先于边界退出时递送的中断。
                acquisition_error = error
              end
            end
            raise acquisition_error, cause: nil if acquisition_error
            return nil unless file

            stat = file.stat
            raise ArgumentError, "saved configuration is not a regular file" unless stat.file?

            file.binmode
            yield file, stat
          rescue Exception # rubocop:disable Lint/RescueException -- 收尾不能覆盖读取故障或用户中断。
            failed = true
            raise acquisition_error, cause: nil if acquisition_error

            raise
          ensure
            cleanup_error = nil
            begin
              Thread.handle_interrupt(Exception => :never) do
                begin
                  file&.close
                rescue Exception => error # rubocop:disable Lint/RescueException -- 在递送待处理中断前登记关闭故障。
                  cleanup_error = error
                end
              end
            rescue Exception => error # rubocop:disable Lint/RescueException -- 待处理中断不能覆盖已登记的关闭故障。
              cleanup_error ||= error
            end
            raise cleanup_error, cause: nil if cleanup_error && !failed
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
