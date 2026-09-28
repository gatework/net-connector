# frozen_string_literal: true

require "time"
require_relative "diagnostic"

module Net
  module Connector
    module Netdisco
      # 单台设备的最终结果，保留状态、配置产物和错误类型。
      Outcome = Data.define(:device, :status, :backup, :error_code, :error_type,
                            :started_at, :finished_at, :duration_ms, :diagnostic) do
        # 创建结果，允许计划阶段尚无执行时间。
        def initialize(device:, status:, backup:, error_code:, error_type:, started_at: nil, finished_at: nil,
                       duration_ms: nil, diagnostic: nil)
          unless duration_ms.nil? || (duration_ms.is_a?(Numeric) && duration_ms.real? && duration_ms.finite? && duration_ms >= 0)
            raise ArgumentError, "duration_ms must be nonnegative and finite"
          end
          raise ArgumentError, "diagnostic must be a Diagnostic" unless diagnostic.nil? || diagnostic.instance_of?(Diagnostic)

          super(device: device, status: status, backup: backup, error_code: error_code, error_type: error_type,
                started_at: started_at, finished_at: finished_at, duration_ms: duration_ms, diagnostic: diagnostic)
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
        def skipped? = !success? && !partial? && status != :failed
      end

      # 汇总一次批量任务的设备结果、回调故障和报告写入状态。
      Batch = Data.define(:mode, :outcomes, :started_at, :finished_at, :callback_errors,
                          :report_location, :report_error) do
        # 按设备最终状态统计数量。
        def counts = outcomes.map(&:status).tally

        # 仅在所有设备成功且回调、报告均正常时判定整批成功。
        def success? = !outcomes.empty? && outcomes.all?(&:success?) && callback_errors.empty? && report_error.nil?

        # 空清单与已尝试但未全部成功的批次分别标记。
        def status = outcomes.empty? ? :no_devices : (success? ? :succeeded : :incomplete)

        # 显式从原始执行结果构造报告。
        def build_report(policy: :strict) = Report.new(self, policy: policy)
      end

      autoload :Report, File.expand_path("report", __dir__)
    end
  end
end
