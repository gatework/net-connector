# frozen_string_literal: true

require_relative "../../storage/file_reader"
require_relative "../../storage/backup_lock"
require_relative "../../device/tftp/receipt"
require_relative "../diagnostic"
require "tempfile"
require_relative "root"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 只核验本次设备回执指向的本地服务器文件；远端可读不等于本次上传证据。
        class Verifier
          # 识别本地或 SSH 核验根目录，本地路径解析为真实目录。
          def initialize(root: nil)
            @remote = Root.remote?(root)
            Root.endpoint(root) if @remote
            @root = root && !@remote ? File.realpath(root) : nil
          end

          # 基线、设备上传和核验共用目标锁；只有上传后变化的文件才属于本次任务。
          def upload_and_verify(device, path: device.tftp_filename)
            outcome = nil
            raise ArgumentError, "SSH TFTP roots require history archival" if @remote
            raise ArgumentError, "upload requires a block" unless block_given?

            TftpTarget.validate_path!(path)
            return yield path unless @root

            destination = server_path(path)
            Storage::BackupLock.synchronize(destination, host: device.host, timeout: 240) do
              previous = Storage::FileReader.open(destination, missing: true) { |_file, stat| stat }
              started_at = Tempfile.create(".net-connector-upload-", @root) { |file| file.stat.mtime }
              outcome = yield path
              outcome = verify_outcome(outcome, started_at: started_at, previous: previous, expected_path: path)
            end
          rescue StandardError => error
            raise unless outcome
            return outcome unless outcome.success?

            # 上传后的核验或解锁故障保留回执，不能让 Worker 把已上传结果退回普通失败。
            diagnostic = Diagnostic.from(error, backup: outcome.backup, phase: :tftp_backup)
            outcome.with(status: :reported_with_error, error_code: diagnostic.error_code,
                         error_type: diagnostic.error_type, diagnostic: diagnostic)
          end

          # 调用者必须在目标锁内先捕获基线；nil 明确表示上传前文件缺失，不能事后猜测。
          def verify_outcome(outcome, started_at:, previous:, expected_path:)
            return outcome unless @root && started_at && outcome.backup.is_a?(TftpReceipt) && outcome.backup.path
            return outcome unless outcome.backup.path == expected_path

            verify(outcome, outcome.backup, started_at: started_at, previous: previous)
          end

          private

          # 解析回执中的相对路径，要求其父目录仍位于配置根目录之内。
          def server_path(relative_path)
            path = File.join(@root, relative_path)
            parent = File.realpath(File.dirname(path))
            unless parent == @root || parent.start_with?(@root + File::SEPARATOR)
              raise ArgumentError, "TFTP verification path escaped its root"
            end

            path
          end

          # 只核验上传后变化且稳定的非空文件，记录摘要与大小但不抹去原设备回执。
          def verify(outcome, receipt, started_at:, previous:)
            path = server_path(receipt.path)
            size = nil
            fingerprint = Storage::FileReader.open(path, missing: true) do |file, stat|
              next unless stat.size.positive? && stat.mtime >= started_at
              next if previous && same_file_state?(previous, stat)

              size = stat.size
              value = Storage::FileReader.fingerprint_io(path, file, stat)
              after = file.stat
              value if [stat.size, stat.mtime, stat.ctime] == [after.size, after.mtime, after.ctime]
            end
            return outcome unless fingerprint && Storage::FileReader.same_entry?(path, fingerprint)

            outcome.with(backup: receipt.with(verification: :server_verified, server_sha256: fingerprint.sha256, server_bytes: size, local_path: path))
          rescue IOError, SystemCallError, ArgumentError
            # 核验失败不抹去设备上传回执；要求服务器证据的策略仍判为未完成。
            outcome
          end

          # 内容相同的重新上传仍有效；但未变化的旧文件不能仅凭未来 mtime 冒充新上传。
          def same_file_state?(before, after)
            [before.dev, before.ino, before.size, before.mtime, before.ctime] ==
              [after.dev, after.ino, after.size, after.mtime, after.ctime]
          end
        end
      end
    end
  end
end
