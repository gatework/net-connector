# frozen_string_literal: true

require_relative "../worker"
require_relative "../planner"
require_relative "../report"
require_relative "../settings"
require_relative "../../device/tftp/target"

module Net
  module Connector
    module Netdisco
      class Fleet
        # 内部参数对象只集中校验和所有权；Fleet 保留公开关键字入口。
        module Options
          # 返回经校验的更新快照，未更新时沿用当前对象。
          def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

          # 统一校验并发、采样、成功策略与可调用回调，尚不创建线程。
          def self.validate!(parallel:, limit:, policy:, callbacks:)
            Worker.validate_parallel!(parallel)
            Planner.validate_limit!(limit)
            Report.validate_policy!(policy)
            callbacks.each do |name, callback|
              raise ArgumentError, "#{name} must respond to call" if callback && !callback.respond_to?(:call)
            end
          end

        end
        private_constant :Options

        # @api private
        BackupOptions = Data.define(:directory, :parallel, :limit_per_vendor, :success_policy,
                                    :filename_style, :on_start, :on_result, :on_change) do
          include Options

          # 校验并复制批次参数，固定业务策略与回调引用。
          def initialize(directory:, parallel:, limit_per_vendor: nil, success_policy: :strict,
                         filename_style: :ip, on_start: nil, on_result: nil, on_change: nil)
            raise ArgumentError, "filename style must be ip or hostname_ip" unless %i[ip hostname_ip].include?(filename_style)
            raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?
            raise ArgumentError, "verified policy requires TFTP mode" if success_policy == :verified

            Options.validate!(parallel: parallel, limit: limit_per_vendor, policy: success_policy,
                                   callbacks: { on_start: on_start, on_result: on_result, on_change: on_change })
            super(directory: directory.dup.freeze, parallel: parallel, limit_per_vendor: limit_per_vendor,
                  success_policy: success_policy, filename_style: filename_style, on_start: on_start, on_result: on_result, on_change: on_change)
          end

          # 返回本地备份批次的报告输出目录。
          def report_directory = directory

          # 组合结果通知与配置变更通知，只对有变化的备份触发变更回调。
          def callbacks
            result = [on_result]
            result << ->(outcome) { on_change.call(outcome) if outcome.backup.is_a?(Backup) && outcome.backup.changed? } if on_change
            result.compact
          end
        end

        # @api private
        TftpOptions = Data.define(:server, :source_files, :vrfs, :parallel, :limit_per_vendor, :report_directory,
                                  :success_policy, :verification_root, :preserve_history, :on_start, :on_result, :servers, :verification_roots) do
          include Options

          # 校验 TFTP 服务器、路由、源文件和核验要求，复制批次执行参数。
          def initialize(server:, parallel:, report_directory:, source_files: {}, vrfs: {}, limit_per_vendor: 5,
                         success_policy: :strict, verification_root: nil, preserve_history: false, on_start: nil, on_result: nil,
                         servers: {}, verification_roots: {})
            Options.validate!(parallel: parallel, limit: limit_per_vendor, policy: success_policy,
                                   callbacks: { on_start: on_start, on_result: on_result })
            unless servers.is_a?(Hash) && verification_roots.is_a?(Hash)
              raise ArgumentError, "TFTP servers and verification_roots must be mappings"
            end
            if success_policy == :verified && !verification_root && verification_roots.empty?
              raise ArgumentError, "verified policy requires a local TFTP directory"
            end
            raise ArgumentError, "source_files must be a Hash" unless source_files.is_a?(Hash)

            server = TftpTarget.new(host: server, path: "preflight.cfg").host if server
            raise ArgumentError, "TFTP requires a default server or device servers" if !server && servers.empty?

            Device::Policy.new(source_files, vendors: %i[h3c h3c_wireless huawei]) { |value| TftpTarget.validate_source_file!(value) unless value.nil? }
            vrfs = Settings.validate_vrfs!(vrfs)
            super(server: server, source_files: source_files.transform_values { |value| value.dup.freeze }.freeze,
                  vrfs: vrfs.transform_values { |value| value.dup.freeze }.freeze, parallel: parallel,
                  limit_per_vendor: limit_per_vendor, report_directory: report_directory&.dup&.freeze,
                  success_policy: success_policy, verification_root: verification_root&.dup&.freeze,
                  preserve_history: preserve_history, on_start: on_start, on_result: on_result,
                  servers: servers.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze,
                  verification_roots: verification_roots.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze)
          end

          # 返回本批次需要执行的非空结果通知回调。
          def callbacks = [on_result].compact
        end
        private_constant :BackupOptions, :TftpOptions
      end
    end
  end
end
