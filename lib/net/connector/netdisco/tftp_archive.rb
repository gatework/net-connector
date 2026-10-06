# frozen_string_literal: true

require "fileutils"
require_relative "../storage/backup_lock"
require_relative "../storage/private_file"
require_relative "../storage/safe_file"
require_relative "tftp_verification"

module Net
  module Connector
    module Netdisco
      # 设备先上传到服务器根目录，核验后按批次归档；固定文件名不会覆盖历史文件。
      class TftpArchive
        BATCH_DIRECTORY_NAME = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d{2})?\z/
        private_constant :BATCH_DIRECTORY_NAME

        class Unavailable < Net::Connector::Error
          def initialize(host: nil)
            super("a local TFTP root is required to retain a fixed-name upload", code: :tftp_history_unavailable,
                  host: host, phase: :tftp_backup)
          end
        end

        class ArchiveFailed < Net::Connector::Error
          def initialize(host: nil)
            super("the uploaded file could not be retained in the batch", code: :tftp_archive_failed,
                  host: host, phase: :tftp_backup)
          end
        end

        def initialize(directory:, root: nil)
          @report_directory = File.expand_path(directory)
          @server_root = root && File.realpath(root)
          @server_archive_directory = create_server_archive_directory if @server_root
          @remote_suffix = reserve_remote_suffix unless @server_root
          @verifier = TftpVerification.new(root: @server_root)
        end

        def upload_filename(device)
          name = device.tftp_filename
          return name if @server_root || device.vendor == :palo_alto

          extension = File.extname(name)
          stem = File.basename(name, extension)
          suffix = "-#{@remote_suffix}#{extension}"
          TftpTarget.validate_path!("#{stem.byteslice(0, TftpTarget::MAX_PATH_BYTES - suffix.bytesize)}#{suffix}")
        end

        def upload_and_archive(device, started_at:)
          raise Unavailable.new(host: device.host) if device.vendor == :palo_alto && !@server_root

          remote_filename = upload_filename(device)
          return yield remote_filename unless @server_root

          # 固定文件名的基线与上传时间都在锁内采集；排队期间前一设备的文件不属于本次上传。
          Storage::BackupLock.synchronize(File.join(@server_root, remote_filename), host: device.host, timeout: 240) do
            previous = archive_existing_file(device, remote_filename)
            upload_started_at = Time.now.utc
            outcome = yield remote_filename
            receipt = outcome.backup
            return outcome unless receipt.is_a?(TftpReceipt) && receipt.path

            verified = @verifier.verify_outcome(outcome.with(started_at: started_at), started_at: upload_started_at, previous: previous)
            return outcome.success? ? archive_failure(outcome) : outcome unless verified.backup.verification == :server_verified

            archive_uploaded_file(verified)
          end
        end

        alias path_for upload_filename
        alias capture upload_and_archive

        private

        # 首次采用固定远端名时，先保留服务器上原有文件，再允许设备覆盖。
        def archive_existing_file(device, remote_filename)
          existing_path = File.join(@server_root, remote_filename)
          bytes, previous = Storage::SafeFile.open(existing_path, missing: true) { |file, stat| [file.read, stat] }
          return unless bytes

          previous_directory = File.join(@server_archive_directory, "previous")
          FileUtils.mkdir_p(previous_directory, mode: 0o700)
          archive_path = File.join(previous_directory, archive_filename(device, File.extname(remote_filename)))
          Storage::PrivateFile.write(archive_path, bytes)
          previous
        rescue StandardError
          raise ArchiveFailed.new(host: device.host), cause: nil
        end

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

        def batch_name
          name = File.basename(@report_directory)
          name.match?(BATCH_DIRECTORY_NAME) ? name : Time.now.getlocal("+08:00").strftime("%Y-%m-%d_%H-%M-%S")
        end

        def archive_uploaded_file(outcome)
          receipt = outcome.backup
          saved_batch_path = nil
          batch_directory = File.join(@report_directory, "tftp")
          FileUtils.mkdir_p(batch_directory, mode: 0o700)
          extension = File.extname(receipt.path)
          filename = archive_filename(outcome.device, extension)
          batch_archive_path = File.join(batch_directory, filename)
          server_archive_path = File.join(@server_archive_directory, filename)
          uploaded_path = receipt.local_path
          bytes = Storage::SafeFile.open(uploaded_path) do |file, stat|
            raise ArchiveFailed.new(host: outcome.device.host) unless stat.size == receipt.server_bytes

            file.read
          end
          raise ArchiveFailed.new(host: outcome.device.host) unless Digest::SHA256.hexdigest(bytes) == receipt.server_sha256

          Storage::PrivateFile.write(batch_archive_path, bytes)
          saved_batch_path = batch_archive_path
          Storage::PrivateFile.write(server_archive_path, bytes)
          if outcome.success?
            uploaded_fingerprint = Storage::SafeFile.fingerprint(uploaded_path)
            raise ArchiveFailed.new(host: outcome.device.host) unless uploaded_fingerprint.sha256 == receipt.server_sha256
            raise ArchiveFailed.new(host: outcome.device.host) unless Storage::SafeFile.same_entry?(uploaded_path, uploaded_fingerprint)

            File.unlink(uploaded_path)
          end
          outcome.with(backup: receipt.with(local_path: batch_archive_path, archive_path: server_archive_path))
        rescue StandardError
          retained = outcome.with(backup: receipt.with(local_path: saved_batch_path))
          outcome.success? ? archive_failure(retained) : retained
        end

        def archive_failure(outcome)
          error = ArchiveFailed.new(host: outcome.device.host)
          outcome.with(status: :reported_with_error, error_code: error.code, error_type: error.class.name,
                       diagnostic: Diagnostic.from(error, backup: outcome.backup))
        end

        def archive_filename(device, extension)
          "#{device.backup_filename(style: :hostname_ip).delete_suffix(".txt")}#{extension}"
        end
      end
    end
  end
end
