# frozen_string_literal: true

require_relative "outcome"

module Net
  module Connector
    module Netdisco
      class Operations
        # 一次操作的结果按请求顺序返回，回调故障与设备故障分别记录。
        Batch = Data.define(:operation, :outcomes, :callback_errors, :started_at, :finished_at) do
          def initialize(operation:, outcomes:, callback_errors:, started_at:, finished_at:)
            unless %i[execute_scripts sync_interface_descriptions plan_interface_descriptions apply_interface_descriptions].include?(operation)
              raise ArgumentError, "operation batch contains an invalid operation"
            end
            unless outcomes.is_a?(Array) && outcomes.all?(Operations::Outcome) && callback_errors.is_a?(Array)
              raise ArgumentError, "operation batch requires outcome and callback error Arrays"
            end
            unless started_at.is_a?(Time) && finished_at.is_a?(Time)
              raise ArgumentError, "operation batch timestamps must be Times"
            end
            super(operation: operation, outcomes: outcomes.dup.freeze,
                  callback_errors: callback_errors.map { |entry| copy_callback_error(entry) }.freeze,
                  started_at: started_at.dup.freeze, finished_at: finished_at.dup.freeze)
          end

          # Ruby 3.2 更新同样重新复制容器；摘要 to_h 不参与领域对象的重建。
          def with(**attributes)
            return self if attributes.empty?

            fields = self.class.members.to_h { |name| [name, public_send(name)] }
            self.class.new(**fields.merge(attributes))
          end

          def success? = !outcomes.empty? && outcomes.all?(&:success?) && callback_errors.empty?

          def counts = outcomes.map(&:status).tally

          def status = outcomes.empty? ? :no_devices : (success? ? :succeeded : :incomplete)

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
              found[outcome.device.host] = outcome.value if outcome.success? && outcome.value.is_a?(Net::Connector::Topology::Plan)
            end.freeze
          end

          def to_h
            { operation: operation, status: status, success: success?, summary: summary, counts: counts,
              started_at: started_at.iso8601, finished_at: finished_at.iso8601,
              outcomes: outcomes.map(&:to_h), callback_errors: callback_errors }
          end

          def inspect = "#<#{self.class} operation=#{operation.inspect} counts=#{counts.inspect}>"

          private

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
