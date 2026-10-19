# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "digest"
require_relative "../../storage/backup_lock"
require_relative "../../storage/atomic_file"
require_relative "../../storage/file_reader"
require_relative "verifier"
require_relative "../diagnostic"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 设备先上传到服务器根目录，核验后按批次归档；固定文件名不会覆盖历史文件。
        class Archive
          # 按根目录类型选择本地或 SSH 归档器，上传流程保持相同回执契约。
          def self.new(directory:, root: nil, ssh_password: nil, parallel: 4)
            if Root.remote?(root)
              require_relative "../ssh/archive"
              return SSH::Archive::Pool.new(directory: directory, root: root, password: ssh_password, parallel: parallel)
            end

            super(directory: directory, root: root)
          end

          BATCH_DIRECTORY_NAME = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d{2})?\z/
          private_constant :BATCH_DIRECTORY_NAME

          # 固定名上传无法保留历史时，在设备上传之前拒绝执行。
          class Unavailable < Net::Connector::Error
            # 构造固定文件名无法安全保留历史的预检错误。
            def initialize(host: nil)
              super("a local or SSH TFTP archive root is required to retain a fixed-name upload", code: :tftp_history_unavailable,
                    host: host, phase: :tftp_backup)
            end
          end

          # 设备可能已经上传，归档失败不能撤销或重新执行设备命令。
          class Failure < Net::Connector::Error
            # 构造上传已经发生但归档未完成的错误，不允许据此自动重放。
            def initialize(host: nil)
              super("the uploaded file could not be retained in the batch", code: :tftp_archive_failed,
                    host: host, phase: :tftp_backup)
            end
          end

          # 固定本地报告和服务器根目录，建立归档批次或唯一上传后缀。
          def initialize(directory:, root: nil)
            @report_directory = File.expand_path(directory)
            @server_root = root && File.realpath(root)
            FileUtils.mkdir_p(@report_directory, mode: 0o700)
            @server_archive_directory = create_server_archive_directory if @server_root
            @remote_suffix = reserve_remote_suffix unless @server_root
            @verifier = Tftp::Verifier.new(root: @server_root)
          end

          # 有本机根目录时保留原名并归档；远端服务器使用批次后缀避免重复覆盖。
          def upload_filename(device)
            name = device.tftp_filename
            return name if @server_root || device.vendor == :palo_alto

            extension = File.extname(name)
            stem = File.basename(name, extension)
            suffix = "-#{@remote_suffix}#{extension}"
            TftpTarget.validate_path!("#{stem.byteslice(0, TftpTarget::MAX_PATH_BYTES - suffix.bytesize)}#{suffix}")
          end

          # 上传与归档在同一目标锁内完成，后续失败仍保留可确认的上传回执和提交路径。
          def upload_and_archive(device, started_at:)
            outcome = nil
            raise Unavailable.new(host: device.host) if device.vendor == :palo_alto && !@server_root

            remote_filename = upload_filename(device)
            return yield remote_filename unless @server_root

            # 固定文件名的基线与上传时间都在锁内采集；排队期间前一设备的文件不属于本次上传。
            Storage::BackupLock.synchronize(File.join(@server_root, remote_filename), host: device.host, timeout: 240) do
              previous = archive_existing_file(device, remote_filename)
              upload_started_at = server_timestamp
              outcome = yield remote_filename
              receipt = outcome.backup
              next outcome unless receipt.is_a?(TftpReceipt) && receipt.path

              verified = @verifier.verify_outcome(outcome.with(started_at: started_at), started_at: upload_started_at,
                                                  previous: previous, expected_path: remote_filename)
              unless verified.backup.verification == :server_verified
                outcome = outcome.success? ? archive_failure(outcome) : outcome
                next outcome
              end

              outcome = archive_uploaded_file(verified)
            end
          rescue StandardError => error
            raise unless outcome

            # 目标锁的关闭发生在块返回之后；保存最新回执，不能丢失已完成的归档路径。
            outcome.success? ? archive_failure(outcome, persistence_error: error) : outcome
          end

          private

          # 文件系统的 mtime 可能落后于 Time.now；用同一服务器目录的时间建立上传边界。
          def server_timestamp
            Tempfile.create(".net-connector-upload-", @server_root) { |file| file.stat.mtime }
          end

          # 首次采用固定远端名时，先保留服务器上原有文件，再允许设备覆盖。
          def archive_existing_file(device, remote_filename)
            existing_path = File.join(@server_root, remote_filename)
            bytes, previous = Storage::FileReader.open(existing_path, missing: true) { |file, stat| [file.read, stat] }
            return unless bytes

            previous_directory = File.join(@server_archive_directory, "previous")
            FileUtils.mkdir_p(previous_directory, mode: 0o700)
            archive_path = File.join(previous_directory, archive_filename(device, File.extname(remote_filename)))
            Storage::AtomicFile.write(archive_path, bytes)
            previous
          rescue StandardError
            raise Failure.new(host: device.host), cause: nil
          end

          # 拒绝符号链接并原子创建服务器批次目录，重跑时递增序号避免覆盖历史。
          def create_server_archive_directory
            parent = File.join(@server_root, "archive")
            raise ArgumentError, "TFTP archive directory must not be a symlink" if File.symlink?(parent)

            FileUtils.mkdir_p(parent, mode: 0o700)
            raise ArgumentError, "TFTP archive directory escaped its root" unless File.realpath(parent) == parent

            base = batch_name
            number = 0
            loop do
              candidate = number.zero? ? base : "#{base}_#{format("%02d", number)}"
              path = File.join(parent, candidate)
              begin
                Dir.mkdir(path, 0o700)
                return path
              rescue Errno::EEXIST
                number += 1
              end
            end
          end

          # 同一目录重跑时用原子预留的序号区分运行，不依赖随机数或进程 ID。
          def reserve_remote_suffix
            base = batch_name
            number = 0
            loop do
              candidate = number.zero? ? base : "#{base}_#{format("%02d", number)}"
              marker = File.join(@report_directory, ".tftp-run-#{candidate}")
              begin
                File.open(marker, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("\n") }
                return candidate
              rescue Errno::EEXIST
                number += 1
              end
            end
          end

          # 沿用合法报告批次名，否则按固定业务时区生成批次时间名。
          def batch_name
            name = File.basename(@report_directory)
            name.match?(BATCH_DIRECTORY_NAME) ? name : Time.now.getlocal("+08:00").strftime("%Y-%m-%d_%H-%M-%S")
          end

          # 读取并核对已核验文件，分别提交本地与服务器归档，成功后才清理上传文件。
          # 双端文件分别提交并及时登记路径；只有原上传仍匹配已核验摘要时才删除，失败不重放上传。
          def archive_uploaded_file(outcome)
            receipt = outcome.backup
            saved_paths = { local_path: nil, archive_path: nil }
            batch_directory = File.join(@report_directory, "tftp")
            FileUtils.mkdir_p(batch_directory, mode: 0o700)
            extension = File.extname(receipt.path)
            filename = archive_filename(outcome.device, extension)
            batch_archive_path = File.join(batch_directory, filename)
            server_archive_path = File.join(@server_archive_directory, filename)
            uploaded_path = receipt.local_path
            bytes = Storage::FileReader.open(uploaded_path) do |file, stat|
              raise Failure.new(host: outcome.device.host) unless stat.size == receipt.server_bytes

              file.read
            end
            raise Failure.new(host: outcome.device.host) unless Digest::SHA256.hexdigest(bytes) == receipt.server_sha256

            persist_archive(saved_paths, :local_path, batch_archive_path, bytes)
            persist_archive(saved_paths, :archive_path, server_archive_path, bytes)
            if outcome.success?
              uploaded_fingerprint = Storage::FileReader.fingerprint(uploaded_path)
              raise Failure.new(host: outcome.device.host) unless uploaded_fingerprint.sha256 == receipt.server_sha256
              raise Failure.new(host: outcome.device.host) unless Storage::FileReader.same_entry?(uploaded_path, uploaded_fingerprint)

              File.unlink(uploaded_path)
            end
            outcome.with(backup: receipt.with(**saved_paths))
          rescue StandardError => error
            retained = outcome.with(backup: receipt.with(**saved_paths))
            outcome.success? ? archive_failure(retained, persistence_error: error) : retained
          end

          # 路径仅由本次写入器的可信回执确认；同步或清理失败不能抹掉已替换的文件。
          def persist_archive(saved_paths, field, path, bytes)
            Storage::AtomicFile.write(path, bytes)
            saved_paths[field] = path
          rescue StandardError => error
            if Storage::AtomicFile.receipt_error?(error) && error.receipt.committed? && error.receipt.path == path
              saved_paths[field] = path
            end
            raise
          end

          # 保留设备及已保存路径回执，将归档收尾失败标为部分成功。
          def archive_failure(outcome, persistence_error: nil)
            error = Failure.new(host: outcome.device.host)
            diagnostic = Diagnostic.from(error, backup: outcome.backup)
            if Storage::AtomicFile.receipt_error?(persistence_error)
              diagnostic = diagnostic.with(artifact_state: persistence_error.receipt.state, artifact_phase: persistence_error.receipt.phase,
                                            underlying_type: persistence_error.underlying_type)
            end
            outcome.with(status: :reported_with_error, error_code: error.code, error_type: error.class.name,
                         diagnostic: diagnostic)
          end

          # 结合安全设备名、管理地址与原生扩展名生成归档文件名。
          def archive_filename(device, extension)
            "#{device.backup_filename(style: :hostname_ip).delete_suffix(".txt")}#{extension}"
          end
        end
      end
    end
  end
end
