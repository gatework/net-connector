# frozen_string_literal: true

require "forwardable"
require_relative "batch"

module Net
  module Connector
    module Netdisco
      # v2 显式包装旧 Batch；成功策略与清单覆盖分开，默认 Batch JSON 不增加字段。
      class Report
        extend Forwardable
        SUCCESS = %i[backed_up reported_uploaded].freeze
        ATTEMPTED = [*SUCCESS, :failed, :saved_with_error, :reported_with_error].freeze
        IGNORABLE = %i[filtered sample_limit].freeze
        private_constant :SUCCESS, :ATTEMPTED, :IGNORABLE

        attr_reader :batch, :policy, :duration_ms, :report_diagnostic
        def_delegators :@batch, *Batch.members, :success?, :status, :counts

        # selected 必须使用带策略和覆盖信息的 v2；默认 strict 继续使用旧 schema。
        def self.options(policy: :strict, schema: nil)
          raise ArgumentError, "success_policy must be strict or selected" unless %i[strict selected].include?(policy)

          schema = policy == :selected ? 2 : 1 if schema.nil?
          raise ArgumentError, "report_schema must be 1 or 2" unless schema.is_a?(Integer) && [1, 2].include?(schema)
          raise ArgumentError, "selected success policy requires report schema 2" if policy == :selected && schema != 2

          { policy: policy, schema: schema }.freeze
        end

        def initialize(batch, policy: :strict, duration_ms: nil, report_diagnostic: nil)
          self.class.options(policy: policy, schema: 2)
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

        # 旧 success?/status 委托给 Batch；新策略绝不把未知状态当作可忽略跳过。
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

        # 复用旧业务数据，但重新白名单化所有诊断字段，包括手工构造的旧 Batch。
        def summary
          legacy = batch.summary
          legacy.merge(
            schema_version: 2, policy: policy, policy_success: policy_success?, duration_ms: duration_ms,
            coverage: { complete: !outcomes.empty? && outcomes.all? { |item| ATTEMPTED.include?(item.status) },
                        attempted: outcomes.count { |item| ATTEMPTED.include?(item.status) },
                        skipped: outcomes.count { |item| !ATTEMPTED.include?(item.status) } },
            devices: device_summaries(legacy.fetch(:devices)),
            callback_errors: callback_errors.map { |entry| { host: entry[:host], error_type: Diagnostic.type(entry[:error_type]) } },
            report_location: report_location, report_error: Diagnostic.type(report_error),
            report_diagnostic: report_diagnostic&.to_h
          )
        end

        def inspect = "#<#{self.class} policy=#{policy} status=#{status} policy_success=#{policy_success?}>"

        private

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
