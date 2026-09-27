# frozen_string_literal: true

require "forwardable"
require_relative "batch"

module Net
  module Connector
    module Netdisco
      # 唯一的批量报告契约，分开呈现成功策略、清单覆盖和受控诊断。
      class Report
        extend Forwardable
        SUCCESS = %i[backed_up reported_uploaded].freeze
        ATTEMPTED = [*SUCCESS, :failed, :saved_with_error, :reported_with_error].freeze
        IGNORABLE = %i[filtered sample_limit].freeze
        private_constant :SUCCESS, :ATTEMPTED, :IGNORABLE

        attr_reader :batch, :policy, :duration_ms, :report_diagnostic
        def_delegators :@batch, *Batch.members, :success?, :status, :counts

        def self.validate_policy!(policy)
          raise ArgumentError, "success_policy must be strict or selected" unless %i[strict selected].include?(policy)

          policy
        end

        def initialize(batch, policy: :strict, duration_ms: nil, report_diagnostic: nil)
          self.class.validate_policy!(policy)
          raise ArgumentError, "report requires a Batch" unless batch.instance_of?(Batch)
          unless duration_ms.nil? || (duration_ms.is_a?(Numeric) && duration_ms.real? && duration_ms.finite? && duration_ms >= 0)
            raise ArgumentError, "duration_ms must be nonnegative and finite"
          end
          unless report_diagnostic.nil? || report_diagnostic.instance_of?(Diagnostic)
            raise ArgumentError, "report_diagnostic must be a Diagnostic"
          end

          @batch, @policy, @duration_ms, @report_diagnostic = batch, policy, duration_ms, report_diagnostic
          freeze
        end

        # 严格完成情况与所选成功策略分别保留，未知状态不能当作可忽略跳过。
        def policy_success?
          return batch.success? if policy == :strict
          return false unless callback_errors.empty? && report_error.nil?

          outcomes.any? { |item| SUCCESS.include?(item.status) } &&
            outcomes.all? { |item| SUCCESS.include?(item.status) || IGNORABLE.include?(item.status) }
        end

        def with(**attributes)
          self.class.new(batch.with(**attributes), policy: policy, duration_ms: duration_ms,
                          report_diagnostic: report_diagnostic)
        end

        def with_report_error(error, location: nil)
          diagnostic = Diagnostic.from(error, phase: :report)
          self.class.new(batch.with(report_location: location, report_error: diagnostic.error_type),
                          policy: policy, duration_ms: duration_ms, report_diagnostic: diagnostic)
        end

        # 手工构造的批次同样经过诊断白名单，不序列化任意异常内容。
        def summary
          data = batch_summary
          data.merge(
            schema_version: 2, policy: policy, policy_success: policy_success?, duration_ms: duration_ms,
            coverage: { complete: !outcomes.empty? && outcomes.all? { |item| ATTEMPTED.include?(item.status) },
                        attempted: outcomes.count { |item| ATTEMPTED.include?(item.status) },
                        skipped: outcomes.count { |item| !ATTEMPTED.include?(item.status) } },
            devices: device_summaries(data.fetch(:devices)),
            callback_errors: callback_errors.map { |entry| { host: entry[:host], error_type: ErrorMetadata.type(entry[:error_type]) } },
            report_location: report_location, report_error: ErrorMetadata.type(report_error),
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
            failed: outcomes.count { |item| item.status == :failed },
            skipped: outcomes.count(&:skipped?),
            counts: counts,
            callback_errors: callback_errors,
            devices: outcomes.map do |item|
              { host: item.device.host || item.device.source_ip, name: item.device.name,
                vendor: item.device.vendor,
                status: item.status, path: item.backup&.path,
                bytes: item.backup.is_a?(Backup) ? item.backup.bytes : nil,
                sha256: item.backup.is_a?(Backup) ? item.backup.sha256 : nil,
                change: item.backup.is_a?(Backup) ? item.backup.change : nil,
                previous_sha256: item.backup.is_a?(Backup) ? item.backup.previous_sha256 : nil,
                started_at: item.started_at&.iso8601, finished_at: item.finished_at&.iso8601,
                duration_ms: item.duration_ms,
                error_code: item.error_code, error_type: item.error_type }
            end
          }
        end

        def device_summaries(entries)
          entries.zip(outcomes).map do |entry, item|
            diagnostic = item.diagnostic || Diagnostic.new(error_code: item.error_code, error_type: item.error_type)
            entry.merge(error_code: diagnostic.error_code, error_type: diagnostic.error_type,
                        diagnostic: diagnostic.to_h.except(:error_code, :error_type))
          end
        end
      end
    end
  end
end
