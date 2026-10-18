# frozen_string_literal: true

require_relative "../diagnostic"
require_relative "../device"
require_relative "../../engine/result"
require_relative "../../device/topology"
require "time"

module Net
  module Connector
    module Netdisco
      class Operations
        # 设备操作保留领域返回值；公开摘要不展开命令、配置、异常消息或审批证据。
        Outcome = Data.define(:device, :status, :value, :error, :started_at, :finished_at, :duration_ms) do
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
        end

      end
    end
  end
end
