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
        ATTEMPTED_STATUSES = [*SUCCESS_STATUSES, :failed, :saved_with_error, :reported_with_error, :interrupted].freeze
        IGNORABLE_STATUSES = %i[filtered sample_limit].freeze
        private_constant :SUCCESS_STATUSES, :ATTEMPTED_STATUSES, :IGNORABLE_STATUSES

        # 读取固定批次、成功策略、计时及报告诊断。
        attr_reader :batch, :policy, :duration_ms, :report_diagnostic, :log_directory
        # 将批次字段与状态查询委托给唯一批次对象，避免维护第二份执行结果。
        def_delegators :@batch, *Batch.members, :success?, :status, :counts

        # 只接受严格、所选设备或服务器核验三种成功策略。
        def self.validate_policy!(policy)
          raise ArgumentError, "success_policy must be strict, selected or verified" unless %i[strict selected verified].include?(policy)

          policy
        end

        # 校验批次、成功策略与诊断元数据，固定报告对象。
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
          return false if batch.interrupted
          return batch.success? if policy == :strict
          return false unless callback_errors.empty? && report_error.nil?

          return false if policy == :verified && outcomes.any? { |outcome| outcome.success? && !server_verified?(outcome) }

          statuses = counts
          SUCCESS_STATUSES.any? { |status| statuses.key?(status) } &&
            statuses.keys.all? { |status| SUCCESS_STATUSES.include?(status) || IGNORABLE_STATUSES.include?(status) }
        end

        # 返回经校验的更新快照，未更新时沿用当前对象。
        def with(**attributes)
          self.class.new(batch.with(**attributes), policy: policy, duration_ms: duration_ms,
                          report_diagnostic: report_diagnostic, log_directory: log_directory)
        end

        # 保留设备结果，单独记录报告保存失败及可确认的提交位置。
        def with_report_error(error, location: nil)
          diagnostic = Diagnostic.from(error, phase: :report)
          self.class.new(batch.with(report_location: location, report_error: diagnostic.error_type),
                          policy: policy, duration_ms: duration_ms, report_diagnostic: diagnostic, log_directory: log_directory)
        end

        # 统计不创建逐设备明细；文本与进度输出复用此入口，复用批次拥有的状态计数。
        def statistics
          batch_data = batch_summary
          attempted = ATTEMPTED_STATUSES.sum { |status| batch_data[:counts].fetch(status, 0) }
          batch_data.merge(
            schema_version: 2, policy: policy, policy_success: policy_success?, duration_ms: duration_ms,
            coverage: { complete: !outcomes.empty? && attempted == outcomes.size,
                        attempted: attempted, skipped: outcomes.size - attempted },
            callback_errors: callback_errors.map { |entry| { host: entry[:host], error_type: Error::Metadata.type(entry[:error_type]) } },
            report_location: report_location, report_error: Error::Metadata.type(report_error),
            verification: mode == :tftp ? { verified: outcomes.count { |outcome| server_verified?(outcome) },
                                            unverified: outcomes.count { |outcome| outcome.backup.is_a?(TftpReceipt) && !server_verified?(outcome) } } : nil,
            report_diagnostic: report_diagnostic&.to_h
          )
        end

        # 手工构造的批次同样经过诊断白名单，不序列化任意异常内容。
        def summary = statistics.merge(devices: device_summaries)

        # 返回对象的安全摘要，不展开正文或认证凭据。
        def inspect = "#<#{self.class} policy=#{policy} status=#{status} policy_success=#{policy_success?}>"

        private

        # 生成可写入报告及供命令行展示的结构化摘要。
        def batch_summary
          statuses = counts
          succeeded = SUCCESS_STATUSES.sum { |status| statuses.fetch(status, 0) }
          partial = statuses.fetch(:saved_with_error, 0) + statuses.fetch(:reported_with_error, 0)
          failed = statuses.fetch(:failed, 0) + statuses.fetch(:interrupted, 0)
          {
            mode: mode, status: status, started_at: started_at.iso8601, finished_at: finished_at.iso8601,
            total: outcomes.size,
            succeeded: succeeded, partial: partial, failed: failed,
            skipped: outcomes.size - succeeded - partial - failed,
            counts: statuses,
            callback_errors: callback_errors
          }
        end

        # 仅以 TFTP 回执中的服务器核验状态判断是否已有文件证据。
        def server_verified?(outcome)
          outcome.backup.is_a?(TftpReceipt) && outcome.backup.verification == :server_verified
        end

        # 分别输出设备上传回执、服务器核验和双端归档的受控元数据。
        def tftp_summary(outcome)
          receipt = outcome.backup if outcome.backup.is_a?(TftpReceipt)
          { remote_path: receipt&.path, server: receipt&.server,
            configuration_kind: receipt&.configuration_kind, source_file: receipt&.source_file,
            format: receipt&.format, verification: receipt&.verification,
            server_file_verified: server_verified?(outcome), server_sha256: receipt&.server_sha256,
            local_file: receipt&.local_path, server_archive_file: receipt&.archive_path,
            bytes: receipt&.server_bytes, sha256: receipt&.server_sha256 }
        end

        # 将每台设备转换为带产物、计时与白名单诊断的公开报告行。
        def device_summaries
          outcomes.map do |outcome|
            diagnostic = outcome.diagnostic || Diagnostic.new(error_code: outcome.error_code, error_type: outcome.error_type)
            entry = { host: outcome.device.host || outcome.device.source_ip, name: outcome.device.name,
                      vendor: outcome.device.vendor, status: outcome.status, path: outcome.backup&.path,
                      bytes: outcome.backup.is_a?(Backup) ? outcome.backup.bytes : nil,
                      sha256: outcome.backup.is_a?(Backup) ? outcome.backup.sha256 : nil,
                      change: outcome.backup.is_a?(Backup) ? outcome.backup.change : nil,
                      previous_sha256: outcome.backup.is_a?(Backup) ? outcome.backup.previous_sha256 : nil,
                      started_at: outcome.started_at&.iso8601, finished_at: outcome.finished_at&.iso8601,
                      duration_ms: outcome.duration_ms,
                      error_code: diagnostic.error_code, error_type: diagnostic.error_type,
                      diagnostic: diagnostic.to_h.except(:error_code, :error_type) }
            entry = entry.merge(tftp_summary(outcome)) if mode == :tftp
            entry[:session_log] = File.join(log_directory, "#{outcome.device.host.tr(":", "_")}.log") if log_directory && outcome.device.host && outcome.started_at
            entry
          end
        end
      end
    end
  end
end
