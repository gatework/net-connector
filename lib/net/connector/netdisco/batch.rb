# frozen_string_literal: true

require "time"
require_relative "diagnostic"

module Net
  module Connector
    module Netdisco
      # 单台设备的最终结果，保留状态、配置产物和错误类型。
      Outcome = Data.define(:device, :status, :backup, :error_code, :error_type,
                            :started_at, :finished_at, :duration_ms, :diagnostic) do
        # 创建结果，允许计划阶段尚无执行时间；审计时间由结果拥有，不能被通知回调原地更改。
        def initialize(device:, status:, backup:, error_code:, error_type:, started_at: nil, finished_at: nil,
                       duration_ms: nil, diagnostic: nil)
          unless duration_ms.nil? || (duration_ms.is_a?(Numeric) && duration_ms.real? && duration_ms.finite? && duration_ms >= 0)
            raise ArgumentError, "duration_ms must be nonnegative and finite"
          end
          raise ArgumentError, "status must be a Symbol or String" unless status.is_a?(Symbol) || status.is_a?(String)
          raise ArgumentError, "diagnostic must be a Diagnostic" unless diagnostic.nil? || diagnostic.instance_of?(Diagnostic)

          super(device: device, status: status.is_a?(String) ? status.dup.freeze : status, backup: backup, error_code: error_code,
                error_type: error_type.is_a?(String) ? error_type.dup.freeze : error_type,
                started_at: started_at&.dup&.freeze, finished_at: finished_at&.dup&.freeze,
                duration_ms: duration_ms, diagnostic: diagnostic)
        end

        # 修改诊断或时刻时释放不再匹配的派生元数据。
        def with(**attributes)
          return self if attributes.empty?

          values = to_h
          values[:duration_ms] = nil if attributes.key?(:started_at) || attributes.key?(:finished_at)
          values[:diagnostic] = nil if attributes.key?(:error_code) || attributes.key?(:error_type)
          self.class.new(**values.merge(attributes))
        end

        # 判断设备是否完成配置保存或上报上传成功。
        def success? = [:backed_up, :reported_uploaded].include?(status)

        # 判断配置已产生但收尾过程是否出错。
        def partial? = [:saved_with_error, :reported_with_error].include?(status)

        # 判断设备是否因为清单或采样规则未执行。
        def skipped? = !success? && !partial? && !%i[failed interrupted].include?(status)
      end

      # 汇总一次批量任务的设备结果、回调故障和报告写入状态。
      Batch = Data.define(:mode, :outcomes, :started_at, :finished_at, :callback_errors,
                          :report_location, :report_error, :interrupted) do
        # 批次拥有容器与审计元数据；调用方只能通过 with 构造新快照。
        def initialize(mode:, outcomes:, started_at:, finished_at:, callback_errors:, report_location:, report_error:, interrupted: false)
          raise ArgumentError, "interrupted must be boolean" unless [true, false].include?(interrupted)
          unless outcomes.is_a?(Array) && outcomes.all? { |outcome| outcome.instance_of?(Outcome) } && callback_errors.is_a?(Array)
            raise ArgumentError, "batch requires outcome and callback error Arrays"
          end

          outcomes = outcomes.dup.freeze
          @counts = outcomes.each_with_object({}) { |outcome, found| found[outcome.status] = found.fetch(outcome.status, 0) + 1 }.freeze
          super(mode: mode, outcomes: outcomes,
                started_at: started_at&.dup&.freeze, finished_at: finished_at&.dup&.freeze,
                callback_errors: callback_errors.map { |entry| copy_callback_error(entry) }.freeze,
                report_location: report_location&.dup&.freeze, report_error: report_error&.dup&.freeze, interrupted: interrupted)
        end

        # 返回经校验的更新快照，未更新时沿用当前对象。
        def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

        # 只累计最终计数，不创建与清单等长的中间状态数组。
        def counts = @counts.dup

        # 仅在所有设备成功且回调、报告均正常时判定整批成功。
        def success? = !interrupted && !outcomes.empty? && @counts.fetch(:backed_up, 0) + @counts.fetch(:reported_uploaded, 0) == outcomes.size &&
                       callback_errors.empty? && report_error.nil?

        # 空清单与已尝试但未全部成功的批次分别标记。
        def status = interrupted ? :interrupted : (outcomes.empty? ? :no_devices : (success? ? :succeeded : :incomplete))

        # 显式从原始执行结果构造报告。
        def build_report(policy: :strict) = Report.new(self, policy: policy)

        private

        # 复制回调故障的主机与白名单异常类型，不保留原始异常或消息。
        def copy_callback_error(entry)
          unless entry.is_a?(Hash) && (entry[:host].nil? || entry[:host].is_a?(String))
            raise ArgumentError, "callback errors must contain a host and error type"
          end

          { host: entry[:host]&.dup&.freeze, error_type: Error::Metadata.type(entry[:error_type]) }.freeze
        end

      end

      autoload :Report, File.expand_path("report", __dir__)
    end
  end
end
