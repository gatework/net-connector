# frozen_string_literal: true

require "fileutils"
require "digest"

module Net
  module Connector
    module Netdisco
      # 基于已验证的清单快照组织有上限的并发备份。
      class Fleet
        DEFAULT_SETTING = Object.new.freeze
        private_constant :DEFAULT_SETTING

        # 组装清单客户端、规则、凭据与结果存储。
        def initialize(client: nil, settings: Settings.new, rules: nil, credentials: nil, connector_factory: nil,
                       result_store: ResultStore::Text.new)
          @settings = settings
          @client = client
          @rules = rules
          @credentials = credentials
          @connector_factory = connector_factory || ->(device, connection_settings) { device.connector(**connection_settings) }
          @result_store = result_store
          raise ArgumentError, "credentials must respond to call" if @credentials && !@credentials.respond_to?(:call)
          raise ArgumentError, "result_store must respond to write" if result_store && !result_store.respond_to?(:write)
        end

        # 拉取并标记重复管理地址的设备清单。
        def devices
          inventory(@settings.snapshot(mode: :inventory))
        end

        # 规划本地配置备份的设备集合。
        def plan_backup(limit_per_vendor: nil)
          build_plan(:backup, limit_per_vendor, @settings.snapshot(mode: :backup))
        end

        # 规划 TFTP 配置备份的设备集合。
        def plan_tftp_backup(limit_per_vendor: 5)
          build_plan(:tftp, limit_per_vendor, @settings.snapshot(mode: :tftp))
        end

        # 先拉取完整清单，再并发采集并保存设备配置。
        def backup_all(directory: DEFAULT_SETTING, concurrency: DEFAULT_SETTING,
                       limit_per_vendor: nil, plan: nil, on_start: nil, on_result: nil, on_change: nil,
                       success_policy: :strict, report_schema: nil)
          reporting = Report.options(policy: success_policy, schema: report_schema)
          policy = @settings.snapshot(mode: :backup)
          directory = policy.backup_directory if directory.equal?(DEFAULT_SETTING)
          concurrency = policy.concurrency if concurrency.equal?(DEFAULT_SETTING)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?
          Worker.new(concurrency: concurrency)
          Planner.validate_limit!(limit_per_vendor)
          validate_callback!(on_result, :on_result)
          validate_callback!(on_start, :on_start)
          validate_callback!(on_change, :on_change)

          plan ||= build_plan(:backup, limit_per_vendor, policy)
          validate_plan!(plan, :backup)
          callbacks = [on_result]
          callbacks << ->(item) { on_change.call(item) if item.backup.is_a?(Backup) && item.backup.changed? } if on_change
          target_directory = File.expand_path(directory)
          saved_config = Operations::SavedConfig.new(directory: target_directory, indexed: true)
          run_batch(:backup, plan, concurrency: concurrency, report_directory: directory,
                    output_directory: target_directory, policy: policy, reporting: reporting,
                    on_start: on_start, on_result: callbacks.compact) do |device, log_directory|
            backup_one(device, target_directory, log_directory, policy, saved_config)
          end
        end

        # 让设备主动导出配置，在执行前检查同批目标文件名冲突。
        def tftp_backup_all(server:, source_files: {}, concurrency: DEFAULT_SETTING,
                            limit_per_vendor: 5, vrfs: {}, on_start: nil, on_result: nil, plan: nil,
                            report_directory: DEFAULT_SETTING, success_policy: :strict, report_schema: nil)
          reporting = Report.options(policy: success_policy, schema: report_schema)
          policy = @settings.snapshot(mode: :tftp)
          concurrency = policy.concurrency if concurrency.equal?(DEFAULT_SETTING)
          report_directory = policy.backup_directory if report_directory.equal?(DEFAULT_SETTING)
          Worker.new(concurrency: concurrency)
          server = TftpTarget.new(host: server, path: "preflight.cfg").host
          raise ArgumentError, "source_files must be a Hash" unless source_files.is_a?(Hash)
          source_files.each_value { |source_file| TftpTarget.validate_source_file!(source_file) }
          source_files = source_files.transform_values { |value| value.dup.freeze }.freeze
          vrfs = Settings.validate_vrfs!(vrfs).transform_values { |value| value.dup.freeze }.freeze
          Planner.validate_limit!(limit_per_vendor)
          validate_callback!(on_result, :on_result)
          validate_callback!(on_start, :on_start)

          plan ||= build_plan(:tftp, limit_per_vendor, policy)
          validate_plan!(plan, :tftp)
          run_batch(:tftp, plan, concurrency: concurrency, report_directory: report_directory,
                    policy: policy, reporting: reporting, on_start: on_start, on_result: on_result) do |device, log_directory|
            tftp_backup_one(device, server, source_files, log_directory, vrfs, policy)
          end
        end

        private

        # 策略在清单请求之前固定；注入的清单客户端仍由调用方负责其自身生命周期。
        def inventory(policy)
          rows = (@client || @settings.client(policy: policy)).devices
          raise Client::Error, "Netdisco returned an invalid device inventory" unless rows.is_a?(Array)

          rules = @rules || policy.rules
          devices = rows.map { |row| Device.from_row(row, rules: rules) }
          duplicates = devices.group_by(&:host).reject { |host, entries| host.nil? || entries.size == 1 }
          devices.map { |device| duplicates.key?(device.host) ? device.with(issue: :duplicate_host) : device }.freeze
        end

        def build_plan(mode, limit, policy)
          Planner.validate_limit!(limit)
          Planner.new(inventory(policy)).call(mode: mode, limit_per_vendor: limit)
        end

        # 统一组织设备任务、日志目录与报告；Worker 保证单台设备失败不影响其他设备。
        def run_batch(mode, plan, concurrency:, report_directory:, policy:, reporting:, on_start:, on_result:, output_directory: nil)
          worker = Worker.new(concurrency: concurrency)
          started_at = Time.now.utc
          started = monotonic
          outcomes = plan.outcomes.dup
          FileUtils.mkdir_p(output_directory, mode: 0o700) if output_directory && !plan.ready.empty?
          log_directory = policy.log_directory
          FileUtils.mkdir_p(log_directory, mode: 0o700) if log_directory && !plan.ready.empty?
          callback_errors = worker.run(plan.ready, outcomes: outcomes, on_start: on_start, on_result: on_result,
                                       on_error: ->(device, error) { outcome(device, :failed, error: error) }) do |device|
            yield device, log_directory
          end
          batch = Batch.new(mode: mode, outcomes: outcomes.freeze, started_at: started_at,
                            finished_at: Time.now.utc, callback_errors: callback_errors,
                            report_location: nil, report_error: nil)
          if reporting.fetch(:schema) == 2
            batch = Report.new(batch, policy: reporting.fetch(:policy), duration_ms: ((monotonic - started) * 1000).round)
          end
          save_report(batch, directory: report_directory)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # 校验批量任务回调接口。
        def validate_callback!(callback, name)
          raise ArgumentError, "#{name} must respond to call" if callback && !callback.respond_to?(:call)
        end

        # 保存批量报告，记录写入失败而不覆盖设备结果。
        def save_report(batch, directory:)
          return batch unless @result_store

          batch.with(report_location: @result_store.write(batch, directory: directory))
        rescue Operations::PrivateFile::WriteError => error
          # 报告也可能已经原子替换；保留已知位置，不将持久性失败误写成完全没有产物。
          location = error.receipt.path if Operations::PrivateFile.receipt_error?(error) && error.receipt.committed?
          return batch.with_report_error(error, location: location) if batch.instance_of?(Report)

          batch.with(report_location: location, report_error: error.class.name)
        rescue StandardError => error
          return batch.with_report_error(error) if batch.instance_of?(Report)

          batch.with(report_error: error.class.name)
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
                      error_type: error&.class&.name, diagnostic: Diagnostic.from(error, backup: backup))
        end

        # 执行单台设备的 TFTP 导出。
        def tftp_backup_one(device, server, source_files, log_directory, vrfs, policy)
          run_one(device, log_directory, policy, success_status: :reported_uploaded,
                  close_error_status: :reported_with_error, backup_class: TftpBackup) do |connector|
            source_file = source_files.fetch(device.vendor, nil)
            transfer_settings = { host: server, path: device.tftp_filename, source_file: source_file }
            transfer_settings[:vrf] = vrfs.fetch(device.vendor) if vrfs.key?(device.vendor)
            connector.tftp_backup(**transfer_settings)
          end
        end

        # 执行单台设备的本地配置采集。
        def backup_one(device, directory, log_directory, policy, saved_config)
          destination = File.join(directory, device.backup_filename)
          Operations::BackupLock.synchronize(destination, host: device.host) do |path_lock|
            previous = saved_config.fingerprint(device.host, required: false)
            previous_digest = previous.sha256 if previous && previous.path != destination
            result = run_one(device, log_directory, policy, success_status: :backed_up,
                             close_error_status: :saved_with_error, backup_class: Backup) do |connector|
              path_lock.delegate { connector.backup(path: destination) }
            end
            backup = result.backup
            next result unless backup.is_a?(Backup) && backup.change == :created && previous_digest

            result.with(backup: backup.with(previous_sha256: previous_digest,
                                           change: backup.sha256 == previous_digest ? :unchanged : :changed))
          end
        end

        # 隔离单台设备的凭据、连接、操作和关闭异常。
        def run_one(device, log_directory, policy, success_status:, close_error_status:, backup_class:)
          connection_settings = @credentials ? @credentials.call(device) : @settings.device_credentials_for(device)
          return outcome(device, :missing_credentials) if connection_settings.nil?
          unless connection_settings.is_a?(Hash) && connection_settings.keys.all?(Symbol) &&
                 connection_settings[:username].is_a?(String) && !connection_settings[:username].empty? &&
                 !connection_settings.key?(:host)
            raise ArgumentError, "credential resolver must return settings with username and without host"
          end

          connection_settings = policy.connection_options(device.vendor).merge(connection_settings)
          log_name = device.host.tr(":", "_")
          if log_directory
            connection_settings = connection_settings.merge(log_file: File.join(log_directory, "#{log_name}.log"))
          end
          connector = @connector_factory.call(device, connection_settings)
          backup, failure = perform_one(connector, backup_class) { yield connector }
          return outcome(device, success_status, backup: backup) unless failure

          outcome(device, backup ? close_error_status : :failed, backup: backup, error: failure)
        rescue StandardError => error
          outcome(device, :failed, error: error)
        end

        # 仅信任库定义且产物类型匹配的提交后错误；普通第三方异常上的 backup 字段不代表完成。
        def perform_one(connector, backup_class)
          backup = nil
          failure = nil
          begin
            result = yield
            raise TypeError, "backup operation did not return #{backup_class}" unless result.is_a?(backup_class)

            backup = result
          rescue StandardError => error
            failure = error
            if backup_class == Backup && error.instance_of?(BackupPersistenceError) && error.backup.instance_of?(Backup)
              backup = error.backup
            elsif backup_class == TftpBackup && error.instance_of?(TftpCompletionError) && error.transfer.instance_of?(TftpBackup)
              backup = error.transfer
            end
          ensure
            begin
              connector.close
            rescue StandardError => error
              failure ||= error
            end
          end
          [backup, failure]
        end
      end
    end
  end
end
