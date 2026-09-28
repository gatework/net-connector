# frozen_string_literal: true

require_relative "../storage/safe_file"

module Net
  module Connector
    module Netdisco
      # 只核验本次设备回执指向的本地服务器文件；远端可读不等于本次上传证据。
      class TftpVerification
        def initialize(root: nil)
          @root = root && File.realpath(root)
        end

        def call(report)
          return report unless @root

          outcomes = report.outcomes.map do |outcome|
            receipt = outcome.backup
            next outcome unless receipt.is_a?(TftpReceipt) && receipt.path && outcome.started_at

            verify(outcome, receipt)
          end
          report.with(outcomes: outcomes.freeze)
        end

        def verify_outcome(outcome)
          return outcome unless @root && outcome.started_at && outcome.backup.is_a?(TftpReceipt) && outcome.backup.path

          verify(outcome, outcome.backup)
        end

        private

        def verify(outcome, receipt)
          path = File.join(@root, receipt.path)
          parent = File.realpath(File.dirname(path))
          return outcome unless parent == @root || parent.start_with?(@root + File::SEPARATOR)

          size = nil
          fingerprint = Storage::SafeFile.open(path, missing: true) do |file, stat|
            next unless stat.size.positive? && stat.mtime >= outcome.started_at

            size = stat.size
            value = Storage::SafeFile.fingerprint_io(path, file, stat)
            after = file.stat
            value if [stat.size, stat.mtime, stat.ctime] == [after.size, after.mtime, after.ctime]
          end
          return outcome unless fingerprint && Storage::SafeFile.same_entry?(path, fingerprint)

          outcome.with(backup: receipt.with(verification: :server_verified, server_sha256: fingerprint.sha256, server_bytes: size, local_path: path))
        rescue IOError, SystemCallError, ArgumentError
          # 核验失败不抹去设备上传回执；要求服务器证据的策略仍判为未完成。
          outcome
        end
      end
    end
  end
end
