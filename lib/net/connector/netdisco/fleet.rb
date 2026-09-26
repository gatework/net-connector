# frozen_string_literal: true

require "fileutils"
require "digest"

module Net
  module Connector
    module Netdisco
      # 基于已验证的清单快照组织有上限的并发备份。
      class Fleet
        # 组装清单客户端、规则、凭据与结果存储。
        def initialize(client: nil, settings: Settings.new, rules: nil, credentials: nil, connector_factory: nil,
                       result_store: ResultStore::Text.new)
          @settings = settings
          @client = client || settings.client
          @rules = rules || settings.rules
          @credentials = credentials || settings.method(:credentials_for)
          @connector_factory = connector_factory || ->(device, connection_settings) { device.connector(**connection_settings) }
          @result_store = result_store
          raise ArgumentError, "credentials must respond to call" unless @credentials.respond_to?(:call)
          raise ArgumentError, "result_store must respond to write" if result_store && !result_store.respond_to?(:write)
        end

        # 拉取并标记重复管理地址的设备清单。
        def devices
          rows = @client.devices
          raise Client::Error, "Netdisco returned an invalid device inventory" unless rows.is_a?(Array)

          devices = rows.map { |row| Device.from_row(row, rules: @rules) }
          duplicates = devices.group_by(&:host).reject { |host, entries| host.nil? || entries.size == 1 }
          devices.map do |device|
            duplicates.key?(device.host) ? device.with(issue: :duplicate_host) : device
          end.freeze
        end

        # 规划本地配置备份的设备集合。
        def plan_backup(limit_per_vendor: nil)
          Planner.new(devices).call(mode: :backup, limit_per_vendor: limit_per_vendor)
        end

        # 规划 TFTP 配置备份的设备集合。
        def plan_tftp_backup(limit_per_vendor: 5)
          Planner.new(devices).call(mode: :tftp, limit_per_vendor: limit_per_vendor)
        end

        # 先拉取完整清单，再并发采集并保存设备配置。
        def backup_all(directory: @settings.backup_directory, concurrency: @settings.concurrency,
                       limit_per_vendor: nil, plan: nil, on_start: nil, on_result: nil, on_change: nil)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?
          Planner.validate_limit!(limit_per_vendor)
          validate_callback!(on_result, :on_result)
          validate_callback!(on_start, :on_start)
          validate_callback!(on_change, :on_change)

          plan ||= plan_backup(limit_per_vendor: limit_per_vendor)
          validate_plan!(plan, :backup)
          callbacks = [on_result]
          callbacks << ->(item) { on_change.call(item) if item.backup.is_a?(Backup) && item.backup.changed? } if on_change
          target_directory = File.expand_path(directory)
          run_batch(:backup, plan, concurrency: concurrency, report_directory: directory,
                   output_directory: target_directory, on_start: on_start, on_result: callbacks.compact) do |device, log_directory|
            backup_one(device, target_directory, log_directory)
          end
        end

        # 让设备主动导出配置，在执行前检查同批目标文件名冲突。
        def tftp_backup_all(server:, source_files: {}, concurrency: @settings.concurrency,
                            limit_per_vendor: 5, vrfs: {}, on_start: nil, on_result: nil, plan: nil,
                            report_directory: @settings.backup_directory)
          TftpTarget.new(host: server, path: "preflight.cfg")
          raise ArgumentError, "source_files must be a Hash" unless source_files.is_a?(Hash)
          source_files.each_value { |source_file| TftpTarget.validate_source_file!(source_file) }
          validate_vrfs!(vrfs)
          Planner.validate_limit!(limit_per_vendor)
          validate_callback!(on_result, :on_result)
          validate_callback!(on_start, :on_start)

          plan ||= plan_tftp_backup(limit_per_vendor: limit_per_vendor)
          validate_plan!(plan, :tftp)
          run_batch(:tftp, plan, concurrency: concurrency, report_directory: report_directory,
                    on_start: on_start, on_result: on_result) do |device, log_directory|
            tftp_backup_one(device, server, source_files, log_directory, vrfs)
          end
        end

        private

        # 统一组织设备任务、日志目录与报告；Worker 保证单台设备失败不影响其他设备。
        def run_batch(mode, plan, concurrency:, report_directory:, on_start:, on_result:, output_directory: nil)
          worker = Worker.new(concurrency: concurrency)
          started_at = Time.now.utc
          outcomes = plan.outcomes.dup
          FileUtils.mkdir_p(output_directory, mode: 0o700) if output_directory && !plan.ready.empty?
          log_directory = @settings.log_directory
          FileUtils.mkdir_p(log_directory, mode: 0o700) if log_directory && !plan.ready.empty?
          callback_errors = worker.run(plan.ready, outcomes: outcomes, on_start: on_start, on_result: on_result,
                                       on_error: ->(device, error) { outcome(device, :failed, error: error) }) do |device|
            yield device, log_directory
          end
          batch = Batch.new(mode: mode, outcomes: outcomes.freeze, started_at: started_at,
                            finished_at: Time.now.utc, callback_errors: callback_errors,
                            report_location: nil, report_error: nil)
          save_report(batch, directory: report_directory)
        end

        # 校验批量任务回调接口。
        def validate_callback!(callback, name)
          raise ArgumentError, "#{name} must respond to call" if callback && !callback.respond_to?(:call)
        end

        # 保存批量报告，记录写入失败而不覆盖设备结果。
        def save_report(batch, directory:)
          return batch unless @result_store

          batch.with(report_location: @result_store.write(batch, directory: directory))
        rescue StandardError => error
          batch.with(report_error: error.class.name)
        end

        # 校验厂商 VRF 映射和名称。
        def validate_vrfs!(vrfs)
          unless vrfs.is_a?(Hash) && vrfs.all? { |vendor, value|
            %i[cisco_nxos hillstone].include?(vendor) && value.is_a?(String) &&
              value.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/)
          }
            raise ArgumentError, "vrfs must map supported vendor names to safe VRF names"
          end
        end

        # 确认传入计划属于当前备份模式。
        def validate_plan!(plan, mode)
          raise ArgumentError, "plan must be a #{mode} Netdisco plan" unless plan.is_a?(Plan) && plan.mode == mode

          plan.validate!
        end

        # 构造包含错误类型的单台设备结果。
        def outcome(device, status, backup: nil, error: nil)
          Outcome.new(device: device, status: status, backup: backup,
                      error_code: error.respond_to?(:code) ? error.code : nil,
                      error_type: error&.class&.name)
        end

        # 执行单台设备的 TFTP 导出。
        def tftp_backup_one(device, server, source_files, log_directory, vrfs)
          run_one(device, log_directory, success_status: :reported_uploaded,
                  close_error_status: :reported_with_error, backup_class: TftpBackup) do |connector|
            source_file = source_files.fetch(device.vendor, nil)
            transfer_settings = { host: server, path: device.tftp_filename, source_file: source_file }
            transfer_settings[:vrf] = vrfs.fetch(device.vendor) if vrfs.key?(device.vendor)
            connector.tftp_backup(**transfer_settings)
          end
        end

        # 执行单台设备的本地配置采集。
        def backup_one(device, directory, log_directory)
          destination = File.join(directory, device.backup_filename)
          previous = Operations::SavedConfig.new(directory: directory).find(device.host, required: false)
          previous_digest = Digest::SHA256.file(previous).hexdigest if previous && previous != destination
          run_one(device, log_directory, success_status: :backed_up,
                  close_error_status: :saved_with_error, backup_class: Backup) do |connector|
            backup = connector.backup(path: destination)
            if backup.is_a?(Backup) && backup.change == :created && previous_digest
              backup.with(previous_sha256: previous_digest,
                          change: backup.sha256 == previous_digest ? :unchanged : :changed)
            else
              backup
            end
          end
        end

        # 隔离单台设备的凭据、连接、操作和关闭异常。
        def run_one(device, log_directory, success_status:, close_error_status:, backup_class:)
          connection_settings = @credentials.call(device)
          return outcome(device, :missing_credentials) if connection_settings.nil?
          unless connection_settings.is_a?(Hash) && connection_settings.keys.all?(Symbol) &&
                 connection_settings[:username].is_a?(String) && !connection_settings[:username].empty? &&
                 !connection_settings.key?(:host)
            raise ArgumentError, "credential resolver must return settings with username and without host"
          end

          log_name = device.host.tr(":", "_")
          if log_directory
            connection_settings = connection_settings.merge(log_file: File.join(log_directory, "#{log_name}.log"))
          end
          connector = @connector_factory.call(device, connection_settings)
          backup = nil
          failure = nil
          begin
            result = yield connector
            raise TypeError, "backup operation did not return #{backup_class}" unless result.is_a?(backup_class)

            backup = result
          rescue StandardError => error
            failure = error
          ensure
            begin
              connector.close
            rescue StandardError => error
              failure ||= error
            end
          end
          return outcome(device, success_status, backup: backup) unless failure

          outcome(device, backup ? close_error_status : :failed, backup: backup, error: failure)
        rescue StandardError => error
          outcome(device, :failed, error: error)
        end
      end
    end
  end
end
