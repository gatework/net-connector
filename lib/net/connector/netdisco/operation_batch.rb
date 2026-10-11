# frozen_string_literal: true

require_relative "diagnostic"
require_relative "device"
require_relative "../engine/result"
require_relative "../device/topology"
require "time"

module Net
  module Connector
    module Netdisco
      # 设备操作保留领域返回值；公开摘要不展开命令、配置、异常消息或审批证据。
      OperationOutcome = Data.define(:device, :status, :value, :error, :started_at, :finished_at, :duration_ms) do
        # 时间对象也可被调用方修改；领域值由操作边界固定，结果不共享可变时间。
        def initialize(device:, status:, value:, error:, started_at:, finished_at:, duration_ms:)
          raise ArgumentError, "operation outcome requires a Device" unless device.is_a?(Device)
          unless %i[succeeded partial failed missing_credentials].include?(status)
            raise ArgumentError, "operation outcome contains an invalid status"
          end
          unless value.nil? || value.is_a?(Result) || value.is_a?(Topology::Plan)
            raise ArgumentError, "operation outcome contains an invalid domain value"
          end
          raise ArgumentError, "operation error must be a StandardError or nil" unless error.nil? || error.is_a?(StandardError)
          validate_state!(status, value, error)
          unless started_at.is_a?(Time) && finished_at.is_a?(Time)
            raise ArgumentError, "operation outcome timestamps must be Times"
          end
          unless duration_ms.is_a?(Numeric) && duration_ms.real? && duration_ms.finite? && duration_ms >= 0
            raise ArgumentError, "operation duration must be nonnegative and finite"
          end

          value = immutable_plan_value(value) if value.is_a?(Topology::Plan)
          super(device: device, status: status, value: value, error: error,
                started_at: started_at.dup.freeze, finished_at: finished_at.dup.freeze, duration_ms: duration_ms)
        end

        def with(**attributes)
          return self if attributes.empty?

          fields = self.class.members.to_h { |name| [name, public_send(name)] }
          self.class.new(**fields.merge(attributes))
        end

        def success? = status == :succeeded

        def partial? = status == :partial

        def to_h
          { host: device.host, vendor: device.vendor, status: status,
            started_at: started_at.iso8601, finished_at: finished_at.iso8601, duration_ms: duration_ms,
            steps: value.is_a?(Result) ? value.steps.size : nil,
            changes: value.is_a?(Topology::Plan) ? value.changes.size : nil,
            diagnostic: Diagnostic.from(error)&.to_h }.compact
        end

        def inspect = "#<#{self.class} host=#{device.host.inspect} status=#{status.inspect}>"

        private

        # 公开更新不能把失败的领域结果改写成成功；首个业务错误与完成步骤仍是权威。
        def validate_state!(status, value, error)
          same_error = !value.is_a?(Result) || value.success? || error.equal?(value.error)
          valid = case status
                  when :succeeded then value && error.nil? && (!value.is_a?(Result) || value.success?)
                  when :partial then value && error && (!value.is_a?(Result) || value.success? || !value.steps.empty?)
                  when :failed then error && (value.nil? || (value.is_a?(Result) && value.failure? && value.steps.empty?))
                  when :missing_credentials then value.nil? && error.nil?
                  end
          raise ArgumentError, "operation state contradicts its domain value or error" unless valid && same_error
        end

        # 外部构造或 with 更新也复制审批树，不仅冻结 Data 的最外层。
        def immutable_plan_value(value)
          case value
          when String then value.frozen? ? value : value.dup.freeze
          when Array then value.map { |item| immutable_plan_value(item) }.freeze
          when Hash then value.to_h { |key, item| [immutable_plan_value(key), immutable_plan_value(item)] }.freeze
          when Topology::Plan, Topology::Change, Topology::Neighbor
            fields = value.to_h.transform_values { |item| immutable_plan_value(item) }
            value.class.new(**fields).freeze
          else value
          end
        end
      end

      # 一次操作的结果按请求顺序返回，回调故障与设备故障分别记录。
      OperationBatch = Data.define(:operation, :outcomes, :callback_errors, :started_at, :finished_at) do
        def initialize(operation:, outcomes:, callback_errors:, started_at:, finished_at:)
          unless %i[execute_scripts sync_interface_descriptions plan_interface_descriptions apply_interface_descriptions].include?(operation)
            raise ArgumentError, "operation batch contains an invalid operation"
          end
          unless outcomes.is_a?(Array) && outcomes.all?(OperationOutcome) && callback_errors.is_a?(Array)
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
            found[outcome.device.host] = outcome.value if outcome.success? && outcome.value.is_a?(Topology::Plan)
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

          { host: entry[:host].dup.freeze, error_type: ErrorMetadata.type(entry[:error_type]) || "StandardError" }.freeze
        end
      end
    end
  end
end
