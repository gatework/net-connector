# frozen_string_literal: true

require_relative "outcome"

module Net
  module Connector
    module Netdisco
      class Operation
        # 一次操作的结果按请求顺序返回，回调故障与设备故障分别记录。
        Batch = Data.define(:operation, :outcomes, :callback_errors, :started_at, :finished_at, :interrupted) do
          # 校验操作类型与结果容器，复制并冻结批次时间及通知故障。
          def initialize(operation:, outcomes:, callback_errors:, started_at:, finished_at:, interrupted: false)
            raise ArgumentError, "operation interruption must be boolean" unless [true, false].include?(interrupted)
            unless %i[execute_scripts sync_descriptions plan_descriptions apply_descriptions].include?(operation)
              raise ArgumentError, "operation batch contains an invalid operation"
            end
            unless outcomes.is_a?(Array) && outcomes.all?(Operation::Outcome) && callback_errors.is_a?(Array)
              raise ArgumentError, "operation batch requires outcome and callback error Arrays"
            end
            if !interrupted && outcomes.any? { |outcome| %i[interrupted not_started].include?(outcome.status) }
              raise ArgumentError, "cancelled operation outcomes require an interrupted batch"
            end
            unless started_at.is_a?(Time) && finished_at.is_a?(Time)
              raise ArgumentError, "operation batch timestamps must be Times"
            end
            super(operation: operation, outcomes: outcomes.dup.freeze,
                  callback_errors: callback_errors.map { |entry| copy_callback_error(entry) }.freeze,
                  started_at: started_at.dup.freeze, finished_at: finished_at.dup.freeze, interrupted: interrupted)
          end

          # Ruby 3.2 更新同样重新复制容器；摘要 to_h 不参与领域对象的重建。
          def with(**attributes)
            return self if attributes.empty?

            fields = self.class.members.to_h { |name| [name, public_send(name)] }
            self.class.new(**fields.merge(attributes))
          end

          # 仅当存在任务、所有设备成功且没有通知故障时返回成功。
          def success? = !interrupted && !outcomes.empty? && outcomes.all?(&:success?) && callback_errors.empty?

          # 按逐设备状态统计本次操作数量。
          def counts = outcomes.map(&:status).tally

          # 区分空任务、完整成功与未完成的操作批次。
          def status = interrupted ? :interrupted : (outcomes.empty? ? :no_devices : (success? ? :succeeded : :incomplete))

          # 清单总数指本批调度设备；部分完成与缺少凭据均计入失败，通知故障单独计数。
          # 设备成功只在操作与关闭均完成后确认，不把远端已经发生的变更解释成可回滚事务。
          def summary
            statuses = counts
            succeeded = statuses.fetch(:succeeded, 0)
            { total: outcomes.size, succeeded: succeeded, failed: outcomes.size - succeeded,
              partial: statuses.fetch(:partial, 0), missing_credentials: statuses.fetch(:missing_credentials, 0),
              callback_errors: callback_errors.size }.freeze
          end

          # 只有完整成功的只读规划自动进入下一阶段；关闭失败的证据仍可从 outcome.value 显式检查。
          def plans
            outcomes.each_with_object({}) do |outcome, found|
              found[outcome.device.host] = outcome.value if outcome.success? && outcome.value.is_a?(Net::Connector::Interfaces::Plan)
            end.freeze
          end

          # 生成不含命令正文和认证字段的公开批次结果。
          def to_h
            { operation: operation, status: status, success: success?, summary: summary, counts: counts, interrupted: interrupted,
              started_at: started_at.iso8601, finished_at: finished_at.iso8601,
              outcomes: outcomes.map(&:to_h), callback_errors: callback_errors }
          end

          # 返回对象的安全摘要，不展开正文或认证凭据。
          def inspect = "#<#{self.class} operation=#{operation.inspect} counts=#{counts.inspect}>"

          private

          # 校验并复制主机与白名单异常类型，隔离任意回调对象。
          def copy_callback_error(entry)
            unless entry.is_a?(Hash) && entry.keys.sort == %i[error_type host] && entry[:host].is_a?(String)
              raise ArgumentError, "callback errors must contain a host and error type"
            end

            { host: entry[:host].dup.freeze, error_type: Error::Metadata.type(entry[:error_type]) || "StandardError" }.freeze
          end
        end
      end
    end
  end
end
