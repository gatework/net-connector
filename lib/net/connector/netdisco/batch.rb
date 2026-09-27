# frozen_string_literal: true

require "time"
require_relative "diagnostic"

module Net
  module Connector
    module Netdisco
      # 单台设备的最终结果，保留状态、配置产物和错误类型。
      Outcome = Data.define(:device, :status, :backup, :error_code, :error_type,
                            :started_at, :finished_at) do
        attr_reader :diagnostic

        # 创建结果，允许计划阶段尚无执行时间。
        def initialize(device:, status:, backup:, error_code:, error_type:, started_at: nil, finished_at: nil,
                       duration_ms: nil, diagnostic: nil)
          unless duration_ms.nil? || (duration_ms.is_a?(Numeric) && duration_ms.real? && duration_ms.finite? && duration_ms >= 0)
            raise ArgumentError, "duration_ms must be nonnegative and finite"
          end
          raise ArgumentError, "diagnostic must be a Diagnostic" unless diagnostic.nil? || diagnostic.instance_of?(Diagnostic)

          @duration_ms, @diagnostic = duration_ms, diagnostic
          super(device: device, status: status, backup: backup, error_code: error_code, error_type: error_type,
                started_at: started_at, finished_at: finished_at)
        end

        # Data 成员保持不变；Worker 加上时间、旧文件迁移调整产物时仍保留内部元数据。
        def with(**attributes)
          return self if attributes.empty?

          metadata = { duration_ms: @duration_ms, diagnostic: diagnostic }
          metadata[:duration_ms] = nil if attributes.key?(:started_at) || attributes.key?(:finished_at)
          metadata[:diagnostic] = nil if attributes.key?(:error_code) || attributes.key?(:error_type)
          self.class.new(**to_h, **metadata.merge(attributes))
        end

        # 判断设备是否完成配置保存或上报上传成功。
        def success? = [:backed_up, :reported_uploaded].include?(status)

        # 判断配置已产生但收尾过程是否出错。
        def partial? = [:saved_with_error, :reported_with_error].include?(status)

        # 判断设备是否因为清单或采样规则未执行。
        def skipped? = !success? && !partial? && status != :failed

        # 计算设备任务的耗时，计划阶段没有时间时返回空值。
        def duration_ms
          return @duration_ms unless @duration_ms.nil?

          [((finished_at - started_at) * 1000).round, 0].max if started_at && finished_at
        end
      end

      # 汇总一次批量任务的设备结果、回调故障和报告写入状态。
      Batch = Data.define(:mode, :outcomes, :started_at, :finished_at, :callback_errors,
                          :report_location, :report_error) do
        # 按设备最终状态统计数量。
        def counts = outcomes.group_by(&:status).transform_values(&:size)

        # 仅在所有设备成功且回调、报告均正常时判定整批成功。
        def success? = !outcomes.empty? && outcomes.all?(&:success?) && callback_errors.empty? && report_error.nil?

        # 空清单与已尝试但未全部成功的批次分别标记。
        def status = outcomes.empty? ? :no_devices : (success? ? :succeeded : :incomplete)

        # 单独请求 v2 包装，不改变旧 Data 的成员、解构或默认 summary。
        def report(policy: :strict) = Report.new(self, policy: policy)

        # 生成可写入报告及供命令行展示的结构化摘要。
        def summary
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
      end

      autoload :Report, File.expand_path("report", __dir__)
    end
  end
end
