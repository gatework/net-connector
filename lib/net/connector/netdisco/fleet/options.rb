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
          def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))

          def self.validate!(concurrency:, limit:, policy:, callbacks:)
            Worker.validate_concurrency!(concurrency)
            Planner.validate_limit!(limit)
            Report.validate_policy!(policy)
            callbacks.each do |name, callback|
              raise ArgumentError, "#{name} must respond to call" if callback && !callback.respond_to?(:call)
            end
          end

        end
        private_constant :Options

        # @api private
        BackupOptions = Data.define(:directory, :concurrency, :limit_per_vendor, :success_policy,
                                    :filename_style, :on_start, :on_result, :on_change) do
          include Options

          def initialize(directory:, concurrency:, limit_per_vendor: nil, success_policy: :strict,
                         filename_style: :ip, on_start: nil, on_result: nil, on_change: nil)
            raise ArgumentError, "filename style must be ip or hostname_ip" unless %i[ip hostname_ip].include?(filename_style)
            raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?
            raise ArgumentError, "verified policy requires TFTP mode" if success_policy == :verified

            Options.validate!(concurrency: concurrency, limit: limit_per_vendor, policy: success_policy,
                                   callbacks: { on_start: on_start, on_result: on_result, on_change: on_change })
            super(directory: directory.dup.freeze, concurrency: concurrency, limit_per_vendor: limit_per_vendor,
                  success_policy: success_policy, filename_style: filename_style, on_start: on_start, on_result: on_result, on_change: on_change)
          end

          def report_directory = directory

          def callbacks
            result = [on_result]
            result << ->(outcome) { on_change.call(outcome) if outcome.backup.is_a?(Backup) && outcome.backup.changed? } if on_change
            result.compact
          end
        end

        # @api private
        TftpOptions = Data.define(:server, :source_files, :vrfs, :concurrency, :limit_per_vendor, :report_directory,
                                  :success_policy, :verification_root, :preserve_history, :on_start, :on_result, :servers, :verification_roots) do
          include Options

          def initialize(server:, concurrency:, report_directory:, source_files: {}, vrfs: {}, limit_per_vendor: 5,
                         success_policy: :strict, verification_root: nil, preserve_history: false, on_start: nil, on_result: nil,
                         servers: {}, verification_roots: {})
            Options.validate!(concurrency: concurrency, limit: limit_per_vendor, policy: success_policy,
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

            VendorDevicePolicy.new(source_files, vendors: %i[h3c h3c_wireless huawei]) { |value| TftpTarget.validate_source_file!(value) unless value.nil? }
            vrfs = Settings.validate_vrfs!(vrfs)
            super(server: server, source_files: source_files.transform_values { |value| value.dup.freeze }.freeze,
                  vrfs: vrfs.transform_values { |value| value.dup.freeze }.freeze, concurrency: concurrency,
                  limit_per_vendor: limit_per_vendor, report_directory: report_directory&.dup&.freeze,
                  success_policy: success_policy, verification_root: verification_root&.dup&.freeze,
                  preserve_history: preserve_history, on_start: on_start, on_result: on_result,
                  servers: servers.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze,
                  verification_roots: verification_roots.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze)
          end

          def callbacks = [on_result].compact
        end
        private_constant :BackupOptions, :TftpOptions
      end
    end
  end
end
