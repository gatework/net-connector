# frozen_string_literal: true

require "forwardable"
require_relative "batch"

module Net
  module Connector
    module Netdisco
      # 唯一的批量报告契约，分开呈现成功策略、清单覆盖和受控诊断。
      class Report
        extend Forwardable
        SUCCESS_STATUSES = %i[backed_up reported_uploaded].freeze
        ATTEMPTED_STATUSES = [*SUCCESS_STATUSES, :failed, :saved_with_error, :reported_with_error].freeze
        IGNORABLE_STATUSES = %i[filtered sample_limit].freeze
        private_constant :SUCCESS_STATUSES, :ATTEMPTED_STATUSES, :IGNORABLE_STATUSES

        attr_reader :batch, :policy, :duration_ms, :report_diagnostic, :log_directory
        def_delegators :@batch, *Batch.members, :success?, :status, :counts

        def self.validate_policy!(policy)
          raise ArgumentError, "success_policy must be strict, selected or verified" unless %i[strict selected verified].include?(policy)

          policy
        end

        def initialize(batch, policy: :strict, duration_ms: nil, report_diagnostic: nil, log_directory: nil)
          self.class.validate_policy!(policy)
          raise ArgumentError, "report requires a Batch" unless batch.instance_of?(Batch)
          unless duration_ms.nil? || (duration_ms.is_a?(Numeric) && duration_ms.real? && duration_ms.finite? && duration_ms >= 0)
            raise ArgumentError, "duration_ms must be nonnegative and finite"
          end
          unless report_diagnostic.nil? || report_diagnostic.instance_of?(Diagnostic)
            raise ArgumentError, "report_diagnostic must be a Diagnostic"
          end

          raise ArgumentError, "verified policy requires TFTP mode" if policy == :verified && batch.mode != :tftp
          @log_directory = log_directory&.dup&.freeze
          @batch, @policy, @duration_ms, @report_diagnostic = batch, policy, duration_ms, report_diagnostic
          freeze
        end

        # 严格完成情况与所选成功策略分别保留，未知状态不能当作可忽略跳过。
        def policy_success?
          return batch.success? if policy == :strict
          return false unless callback_errors.empty? && report_error.nil?

          return false if policy == :verified && outcomes.any? { |outcome| outcome.success? && !server_verified?(outcome) }

          outcomes.any? { |outcome| SUCCESS_STATUSES.include?(outcome.status) } &&
            outcomes.all? { |outcome| SUCCESS_STATUSES.include?(outcome.status) || IGNORABLE_STATUSES.include?(outcome.status) }
        end

        def with(**attributes)
          self.class.new(batch.with(**attributes), policy: policy, duration_ms: duration_ms,
                          report_diagnostic: report_diagnostic, log_directory: log_directory)
        end

        def with_report_error(error, location: nil)
          diagnostic = Diagnostic.from(error, phase: :report)
          self.class.new(batch.with(report_location: location, report_error: diagnostic.error_type),
                          policy: policy, duration_ms: duration_ms, report_diagnostic: diagnostic, log_directory: log_directory)
        end

        # 手工构造的批次同样经过诊断白名单，不序列化任意异常内容。
        def summary
          batch_data = batch_summary
          batch_data.merge(
            schema_version: 2, policy: policy, policy_success: policy_success?, duration_ms: duration_ms,
            coverage: { complete: !outcomes.empty? && outcomes.all? { |outcome| ATTEMPTED_STATUSES.include?(outcome.status) },
                        attempted: outcomes.count { |outcome| ATTEMPTED_STATUSES.include?(outcome.status) },
                        skipped: outcomes.count { |outcome| !ATTEMPTED_STATUSES.include?(outcome.status) } },
            devices: device_summaries(batch_data.fetch(:devices)),
            callback_errors: callback_errors.map { |entry| { host: entry[:host], error_type: ErrorMetadata.type(entry[:error_type]) } },
            report_location: report_location, report_error: ErrorMetadata.type(report_error),
            verification: mode == :tftp ? { verified: outcomes.count { |outcome| server_verified?(outcome) },
                                            unverified: outcomes.count { |outcome| outcome.backup.is_a?(TftpReceipt) && !server_verified?(outcome) } } : nil,
            report_diagnostic: report_diagnostic&.to_h
          )
        end

        def inspect = "#<#{self.class} policy=#{policy} status=#{status} policy_success=#{policy_success?}>"

        private

        # 生成可写入报告及供命令行展示的结构化摘要。
        def batch_summary
          {
            mode: mode, status: status, started_at: started_at.iso8601, finished_at: finished_at.iso8601,
            total: outcomes.size,
            succeeded: outcomes.count(&:success?),
            partial: outcomes.count(&:partial?),
            failed: outcomes.count { |outcome| outcome.status == :failed },
            skipped: outcomes.count(&:skipped?),
            counts: counts,
            callback_errors: callback_errors,
            devices: outcomes.map do |outcome|
              { host: outcome.device.host || outcome.device.source_ip, name: outcome.device.name,
                vendor: outcome.device.vendor,
                status: outcome.status, path: outcome.backup&.path,
                bytes: outcome.backup.is_a?(Backup) ? outcome.backup.bytes : nil,
                sha256: outcome.backup.is_a?(Backup) ? outcome.backup.sha256 : nil,
                change: outcome.backup.is_a?(Backup) ? outcome.backup.change : nil,
                previous_sha256: outcome.backup.is_a?(Backup) ? outcome.backup.previous_sha256 : nil,
                started_at: outcome.started_at&.iso8601, finished_at: outcome.finished_at&.iso8601,
                duration_ms: outcome.duration_ms,
                error_code: outcome.error_code, error_type: outcome.error_type }
            end
          }
        end

        def server_verified?(outcome)
          outcome.backup.is_a?(TftpReceipt) && outcome.backup.verification == :server_verified
        end

        def tftp_summary(outcome)
          receipt = outcome.backup if outcome.backup.is_a?(TftpReceipt)
          { remote_path: receipt&.path, server: receipt&.server,
            configuration_kind: receipt&.configuration_kind, source_file: receipt&.source_file,
            format: receipt&.format, verification: receipt&.verification,
            server_file_verified: server_verified?(outcome), server_sha256: receipt&.server_sha256,
            local_file: receipt&.local_path, server_archive_file: receipt&.archive_path,
            bytes: receipt&.server_bytes, sha256: receipt&.server_sha256 }
        end

        def device_summaries(entries)
          entries.zip(outcomes).map do |entry, outcome|
            diagnostic = outcome.diagnostic || Diagnostic.new(error_code: outcome.error_code, error_type: outcome.error_type)
            entry = entry.merge(tftp_summary(outcome)) if mode == :tftp
            entry[:session_log] = File.join(log_directory, "#{outcome.device.host.tr(":", "_")}.log") if log_directory && outcome.device.host && outcome.started_at
            entry.merge(error_code: diagnostic.error_code, error_type: diagnostic.error_type,
                        diagnostic: diagnostic.to_h.except(:error_code, :error_type))
          end
        end
      end
    end
  end
end
