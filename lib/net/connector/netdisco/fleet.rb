# frozen_string_literal: true

require "fileutils"
require_relative "../storage"
require_relative "../device_session"
require_relative "client"
require_relative "settings"
require_relative "device"
require_relative "worker"
require_relative "operations"
require_relative "result_store"
require_relative "planner"
require_relative "report"
require_relative "tftp_verification"
require_relative "tftp_archive"

module Net
  module Connector
    module Netdisco
      # 基于已验证的清单快照组织有上限的并发备份。
      class Fleet
        attr_reader :inventory_status

        DEFAULT_SETTING = Object.new.freeze
        private_constant :DEFAULT_SETTING

        # 组装清单客户端、规则、凭据与结果存储。
        def initialize(client: nil, settings: Settings.new, rules: nil, credentials: nil, connector_factory: nil,
                       result_store: ResultStore::Json.new)
          @settings = settings
          @client = client
          @rules = rules
          @credentials = credentials
          @connector_factory = connector_factory || ->(device, connection_settings) { device.build_connector(**connection_settings) }
          @result_store = result_store
          raise ArgumentError, "credentials must respond to call" if @credentials && !@credentials.respond_to?(:call)
          raise ArgumentError, "result_store must respond to write" if result_store && !result_store.respond_to?(:write)
        end

        # 拉取并标记重复管理地址的设备清单。
        def devices(force_refresh: false)
          inventory(@settings.snapshot(mode: :inventory), force_refresh: force_refresh)
        end

        # 规划本地配置备份的设备集合。
        def plan_backup(limit_per_vendor: nil, force_refresh: false)
          build_plan(:backup, limit_per_vendor, @settings.snapshot(mode: :backup), force_refresh: force_refresh)
        end

        # 规划 TFTP 配置备份的设备集合。
        def plan_tftp_backup(limit_per_vendor: 5, allow_fixed_name_reuse: false, force_refresh: false)
          build_plan(:tftp, limit_per_vendor, @settings.snapshot(mode: :tftp),
                     allow_fixed_name_reuse: allow_fixed_name_reuse, force_refresh: force_refresh)
        end

        # 先拉取完整清单，再并发采集并保存设备配置。
        def backup_all(directory: DEFAULT_SETTING, concurrency: DEFAULT_SETTING,
                       limit_per_vendor: nil, plan: nil, on_start: nil, on_result: nil, on_change: nil,
                       success_policy: :strict, filename_style: :ip)
          raise ArgumentError, "filename style must be ip or hostname_ip" unless %i[ip hostname_ip].include?(filename_style)

          Report.validate_policy!(success_policy)
          raise ArgumentError, "verified policy requires TFTP mode" if success_policy == :verified
          settings_snapshot = @settings.snapshot(mode: :backup)
          directory = settings_snapshot.backup_directory if directory.equal?(DEFAULT_SETTING)
          concurrency = settings_snapshot.concurrency if concurrency.equal?(DEFAULT_SETTING)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty?
          Worker.validate_concurrency!(concurrency)
          Planner.validate_limit!(limit_per_vendor)
          validate_callback!(on_result, :on_result)
          validate_callback!(on_start, :on_start)
          validate_callback!(on_change, :on_change)

          plan ||= build_plan(:backup, limit_per_vendor, settings_snapshot)
          validate_plan!(plan, :backup)
          callbacks = [on_result]
          callbacks << ->(outcome) { on_change.call(outcome) if outcome.backup.is_a?(Backup) && outcome.backup.changed? } if on_change
          target_directory = File.expand_path(directory)
          run_batch(:backup, plan, concurrency: concurrency, report_directory: directory,
                    output_directory: target_directory, settings_snapshot: settings_snapshot, success_policy: success_policy,
                    on_start: on_start, on_result: callbacks.compact) do |device, log_directory|
            backup_device(device, target_directory, log_directory, settings_snapshot, filename_style: filename_style)
          end
        end

        # 让设备主动导出配置，在执行前检查同批目标文件名冲突。
        def tftp_backup_all(server:, source_files: {}, concurrency: DEFAULT_SETTING,
                            limit_per_vendor: 5, vrfs: {}, on_start: nil, on_result: nil, plan: nil,
                            report_directory: DEFAULT_SETTING, success_policy: :strict, verification_root: nil,
                            preserve_history: false)
          Report.validate_policy!(success_policy)
          raise ArgumentError, "verified policy requires a local TFTP directory" if success_policy == :verified && !verification_root
          verification = TftpVerification.new(root: verification_root)
          settings_snapshot = @settings.snapshot(mode: :tftp)
          concurrency = settings_snapshot.concurrency if concurrency.equal?(DEFAULT_SETTING)
          report_directory = settings_snapshot.backup_directory if report_directory.equal?(DEFAULT_SETTING)
          Worker.validate_concurrency!(concurrency)
          server = TftpTarget.new(host: server, path: "preflight.cfg").host
          raise ArgumentError, "source_files must be a Hash" unless source_files.is_a?(Hash)
          source_files.each_value { |source_file| TftpTarget.validate_source_file!(source_file) }
          source_files = source_files.transform_values { |value| value.dup.freeze }.freeze
          vrfs = Settings.validate_vrfs!(vrfs).transform_values { |value| value.dup.freeze }.freeze
          Planner.validate_limit!(limit_per_vendor)
          validate_callback!(on_result, :on_result)
          validate_callback!(on_start, :on_start)

          plan ||= build_plan(:tftp, limit_per_vendor, settings_snapshot,
                              allow_fixed_name_reuse: preserve_history && !verification_root.nil?)
          validate_plan!(plan, :tftp)
          if plan.allow_fixed_name_reuse && (!preserve_history || !verification_root)
            raise ArgumentError, "fixed-name TFTP uploads require local history archival"
          end
          archive = TftpArchive.new(directory: report_directory, root: verification_root) if preserve_history
          run_batch(:tftp, plan, concurrency: concurrency, report_directory: report_directory,
                    settings_snapshot: settings_snapshot, success_policy: success_policy, on_start: on_start, on_result: on_result) do |device, log_directory|
            if archive
              archive.upload_and_archive(device, started_at: Time.now.utc) do |remote_filename|
                tftp_backup_device(device, server, source_files, log_directory, vrfs, settings_snapshot, path: remote_filename)
              end
            else
              verification.upload_and_verify(device) do |remote_filename|
                tftp_backup_device(device, server, source_files, log_directory, vrfs, settings_snapshot, path: remote_filename)
              end
            end
          end
        end

        # 配置批次在任何连接之前验证全部脚本与目标，写操作须显式确认。
        def execute_scripts(**options)
          operations.execute_scripts(**options)
        end

        # 默认连贯同步，不要求调用方管理计划或重新建立设备连接。
        def sync_interface_descriptions(**options, &)
          operations.sync_interface_descriptions(**options, &)
        end

        # 并发生成接口描述计划，不执行配置变更。
        def plan_interface_descriptions(**options, &)
          operations.plan_interface_descriptions(**options, &)
        end

        # 每台设备独立重验审批证据、回读并保存，不将计划当作普通脚本执行。
        def apply_interface_descriptions(**options)
          operations.apply_interface_descriptions(**options)
        end

        private

        def operations
          Operations.new(settings: @settings, inventory: method(:inventory), credentials: @credentials,
                         connector_factory: @connector_factory)
        end

        # 策略在清单请求之前固定；注入的清单客户端仍由调用方负责其自身生命周期。
        def inventory(settings_snapshot, force_refresh: false)
          @inventory_status = nil
          raise ArgumentError, "force_refresh must be true or false" unless [true, false].include?(force_refresh)

          client = @client || @settings.client(policy: settings_snapshot)
          rows = client.is_a?(InventoryCache) ? client.devices(force_refresh: force_refresh) : client.devices
          @inventory_status = if client.is_a?(InventoryCache)
                                { source: client.status, fetched_at: client.fetched_at,
                                  refresh_error_code: client.refresh_error_code, write_error_type: client.write_error_type }.freeze
                              else
                                { source: :uncached }.freeze
                              end
          raise Client::Error, "Netdisco returned an invalid device inventory" unless rows.is_a?(Array)

          rules = @rules || settings_snapshot.rules
          devices = rows.map { |row| Device.from_row(row, rules: rules) }
          host_counts = devices.each_with_object(Hash.new(0)) { |device, counts| counts[device.host] += 1 if device.host }
          devices.map { |device| host_counts[device.host] > 1 ? device.with(issue: :duplicate_host) : device }.freeze
        end

        def build_plan(mode, limit, settings_snapshot, allow_fixed_name_reuse: false, force_refresh: false)
          Planner.validate_limit!(limit)
          Planner.new(inventory(settings_snapshot, force_refresh: force_refresh)).call(mode: mode, limit_per_vendor: limit,
                                               allow_fixed_name_reuse: allow_fixed_name_reuse)
        end

        # 统一组织设备任务、日志目录与报告；Worker 保证单台设备失败不影响其他设备。
        def run_batch(mode, plan, concurrency:, report_directory:, settings_snapshot:, success_policy:, on_start:, on_result:, output_directory: nil)
          worker = Worker.new(concurrency: concurrency)
          started_at = Time.now.utc
          started = monotonic
          outcomes = plan.outcomes.dup
          FileUtils.mkdir_p(output_directory, mode: 0o700) if output_directory && !plan.ready.empty?
          log_directory = settings_snapshot.log_directory
          FileUtils.mkdir_p(log_directory, mode: 0o700) if log_directory && !plan.ready.empty?
          callback_errors = worker.run(plan.ready, outcomes: outcomes, on_start: on_start, on_result: on_result,
                                       on_error: ->(device, error) { build_outcome(device, :failed, error: error) }) do |device|
            yield device, log_directory
          end
          batch = Batch.new(mode: mode, outcomes: outcomes.freeze, started_at: started_at,
                            finished_at: Time.now.utc, callback_errors: callback_errors,
                            report_location: nil, report_error: nil)
          report = Report.new(batch, policy: success_policy, duration_ms: ((monotonic - started) * 1000).round, log_directory: log_directory)
          save_report(report, directory: report_directory)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # 校验批量任务回调接口。
        def validate_callback!(callback, name)
          raise ArgumentError, "#{name} must respond to call" if callback && !callback.respond_to?(:call)
        end

        # 保存批量报告，记录写入失败而不覆盖设备结果。
        def save_report(report, directory:)
          return report unless @result_store

          report.with(report_location: @result_store.write(report, directory: directory))
        rescue Storage::PrivateFile::WriteError => error
          # 报告也可能已经原子替换；保留已知位置，不将持久性失败误写成完全没有产物。
          location = error.receipt.path if Storage::PrivateFile.receipt_error?(error) && error.receipt.committed?
          report.with_report_error(error, location: location)
        rescue StandardError => error
          report.with_report_error(error)
        end

        # 确认传入计划属于当前备份模式。
        def validate_plan!(plan, mode)
          raise ArgumentError, "plan must be a #{mode} Netdisco plan" unless plan.is_a?(Plan) && plan.mode == mode

          plan.validate!
        end

        # 构造包含错误类型的单台设备结果。
        def build_outcome(device, status, backup: nil, error: nil)
          Outcome.new(device: device, status: status, backup: backup,
                      error_code: error.respond_to?(:code) ? error.code : nil,
                      error_type: error&.class&.name, diagnostic: Diagnostic.from(error, backup: backup))
        end

        # 执行单台设备的 TFTP 导出。
        def tftp_backup_device(device, server, source_files, log_directory, vrfs, settings_snapshot, path: device.tftp_filename)
          run_device(device, log_directory, settings_snapshot, success_status: :reported_uploaded,
                     partial_status: :reported_with_error, backup_class: TftpReceipt) do |connector|
            source_file = source_files.fetch(device.vendor, nil)
            transfer_settings = { host: server, path: path, source_file: source_file }
            transfer_settings[:vrf] = vrfs.fetch(device.vendor) if vrfs.key?(device.vendor)
            connector.tftp_backup(**transfer_settings)
          end
        end

        # 执行单台设备的本地配置采集。
        def backup_device(device, directory, log_directory, settings_snapshot, filename_style: :ip)
          outcome = nil
          destination = File.join(directory, device.backup_filename(style: filename_style))
          Storage::BackupLock.synchronize(destination, host: device.host) do |path_lock|
            Storage::SafeFile.open(destination, missing: true) { |_file, _stat| nil }
            outcome = run_device(device, log_directory, settings_snapshot, success_status: :backed_up,
                                 partial_status: :saved_with_error, backup_class: Backup) do |connector|
              path_lock.with_delegated_lock { connector.backup(path: destination) }
            end
          end
        rescue StandardError => error
          raise unless outcome
          return outcome unless outcome.success?

          build_outcome(device, :saved_with_error, backup: outcome.backup, error: error)
        end

        # 隔离单台设备的凭据、连接、操作和关闭异常。
        def run_device(device, log_directory, settings_snapshot, success_status:, partial_status:, backup_class:, &operation)
          connection_settings = @credentials ? @credentials.call(device) : @settings.device_credentials_for(device)
          return build_outcome(device, :missing_credentials) if connection_settings.nil?
          unless connection_settings.is_a?(Hash) && connection_settings.keys.all?(Symbol) &&
                 connection_settings[:username].is_a?(String) && !connection_settings[:username].empty? &&
                 !connection_settings.key?(:host)
            raise ArgumentError, "credential resolver must return settings with username and without host"
          end

          connection_settings = settings_snapshot.connection_options(device.vendor).merge(connection_settings)
          log_name = device.host.tr(":", "_")
          if log_directory
            connection_settings = connection_settings.merge(log_file: File.join(log_directory, "#{log_name}.log"))
          end
          backup, failure = perform_one(backup_class, factory: -> { @connector_factory.call(device, connection_settings) }) do |connector|
            operation.call(connector)
          end
          return build_outcome(device, success_status, backup: backup) unless failure

          build_outcome(device, backup ? partial_status : :failed, backup: backup, error: failure)
        rescue StandardError => error
          build_outcome(device, :failed, error: error)
        end

        # 仅信任库定义且产物类型匹配的提交后错误；普通第三方异常上的 backup 字段不代表完成。
        def perform_one(backup_class, factory:)
          backup, failure = DeviceSession.call(factory: factory) do |session|
            result = yield session
            raise TypeError, "backup operation did not return #{backup_class}" unless result.is_a?(backup_class)

            result
          end
          if failure && backup.nil?
            if backup_class == Backup && [BackupPersistenceError, BackupFinalizeError].any? { |type| failure.instance_of?(type) } &&
               failure.backup.instance_of?(Backup)
              backup = failure.backup
            elsif backup_class == TftpReceipt && failure.instance_of?(TftpCompletionError) && failure.receipt.instance_of?(TftpReceipt)
              backup = failure.receipt
            end
          end
          [backup, failure]
        end
      end
    end
  end
end
