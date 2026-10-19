# frozen_string_literal: true

require "fileutils"
require_relative "../storage"
require_relative "../device/scope"
require_relative "inventory"
require_relative "settings"
require_relative "device"
require_relative "device/access"
require_relative "worker"
require_relative "operations"
require_relative "report/store"
require_relative "planner"
require_relative "report"
require_relative "tftp/verifier"
require_relative "tftp/archive"
require_relative "fleet/options"
require_relative "resources"

module Net
  module Connector
    module Netdisco
      # 基于已验证的清单快照组织有上限的并发备份。
      class Fleet
        # 读取清单来源诊断及最近一次可用批次报告，包括中断后的部分结果。
        attr_reader :inventory_status, :last_report

        DEFAULT_SETTING = Object.new.freeze
        private_constant :DEFAULT_SETTING

        # 组装清单来源、规则、凭据与结果存储。
        def initialize(inventory: nil, settings: Settings.new, rules: nil, credentials: nil, connector_factory: nil,
                       report_store: Report::Store::Json.new)
          @settings = settings
          @inventory = inventory
          @rules = rules
          @credentials = credentials
          @connector_factory = connector_factory || ->(device, access_options) { device.build_connector(**access_options) }
          @report_store = report_store
          raise ArgumentError, "credentials must respond to call" if @credentials && !@credentials.respond_to?(:call)
          raise ArgumentError, "report_store must respond to write" if report_store && !report_store.respond_to?(:write)
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
        def backup_all(directory: DEFAULT_SETTING, parallel: DEFAULT_SETTING,
                       limit_per_vendor: nil, plan: nil, on_start: nil, on_result: nil, on_change: nil,
                       success_policy: :strict, filename_style: :ip)
          @last_report = nil
          settings_snapshot = @settings.snapshot(mode: :backup)
          directory = settings_snapshot.backup_directory if directory.equal?(DEFAULT_SETTING)
          parallel = settings_snapshot.parallel if parallel.equal?(DEFAULT_SETTING)
          options = BackupOptions.new(directory: directory, parallel: parallel, limit_per_vendor: limit_per_vendor,
                                      success_policy: success_policy, filename_style: filename_style,
                                      on_start: on_start, on_result: on_result, on_change: on_change)

          plan ||= build_plan(:backup, limit_per_vendor, settings_snapshot)
          validate_plan!(plan, :backup)
          target_directory = File.expand_path(options.directory)
          run_batch(:backup, plan, options: options, output_directory: target_directory, settings_snapshot: settings_snapshot) do |device, log_directory|
            backup_device(device, target_directory, log_directory, settings_snapshot, filename_style: options.filename_style)
          end
        end

        # 让设备主动导出配置，在执行前检查同批目标文件名冲突。
        def tftp_backup_all(server: DEFAULT_SETTING, source_files: DEFAULT_SETTING, parallel: DEFAULT_SETTING,
                            limit_per_vendor: 5, vrfs: DEFAULT_SETTING, source_interfaces: DEFAULT_SETTING, servers: DEFAULT_SETTING, verification_roots: DEFAULT_SETTING, on_start: nil, on_result: nil, plan: nil,
                            report_directory: DEFAULT_SETTING, success_policy: :strict, verification_root: DEFAULT_SETTING,
                            preserve_history: false)
          @last_report = nil
          settings_snapshot = @settings.snapshot(mode: :tftp)
          transfer_options = tftp_transfer_options(settings_snapshot, server: server, source_files: source_files, vrfs: vrfs,
                                                    source_interfaces: source_interfaces, servers: servers,
                                                    verification_roots: verification_roots, verification_root: verification_root)
          policy = Tftp::Policy.new(**transfer_options)
          server, source_files, vrfs = transfer_options.values_at(:server, :source_files, :vrfs)
          verification_root, verification_roots = transfer_options.values_at(:verification_root, :verification_roots)
          parallel = settings_snapshot.parallel if parallel.equal?(DEFAULT_SETTING)
          report_directory = settings_snapshot.backup_directory if report_directory.equal?(DEFAULT_SETTING)
          options = TftpOptions.new(server: server, source_files: source_files, vrfs: vrfs, parallel: parallel,
                                    limit_per_vendor: limit_per_vendor, report_directory: report_directory,
                                    success_policy: success_policy, verification_root: verification_root,
                                    preserve_history: preserve_history, on_start: on_start, on_result: on_result,
                                    servers: transfer_options.fetch(:servers), verification_roots: verification_roots)
          report_directory = options.report_directory
          unless plan
            devices = inventory(settings_snapshot)
            plan = Planner.new(devices).call(mode: :tftp, limit_per_vendor: limit_per_vendor, tftp_policy: policy,
                                             allow_fixed_name_reuse: preserve_history && (!verification_root.nil? || !verification_roots.empty?))
          end
          validate_plan!(plan, :tftp)
          transfers = tftp_plan_options(plan, policy, success_policy: success_policy, preserve_history: preserve_history)
          contexts = tftp_contexts(plan, transfers, report_directory: report_directory, preserve_history: preserve_history, parallel: [parallel, plan.selected.size].min)
          contexts.each_value { |archive, _verification| archive.prepare if archive.respond_to?(:prepare) }
          run_batch(:tftp, plan, options: options, settings_snapshot: settings_snapshot) do |device, log_directory|
            transfer = transfers.fetch(device.host)
            archive, verification = contexts.fetch(transfer.server)
            if archive
              archive.upload_and_archive(device, started_at: Time.now.utc) do |remote_filename|
                tftp_backup_device(device, transfer, log_directory, settings_snapshot, path: remote_filename)
              end
            else
              verification.upload_and_verify(device) do |remote_filename|
                tftp_backup_device(device, transfer, log_directory, settings_snapshot, path: remote_filename)
              end
            end
          end
        ensure
          close_tftp_contexts(contexts, primary_failure: $!)
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

        # 尝试关闭本批次的全部归档连接；清理失败不能覆盖原业务故障或中断。
        def close_tftp_contexts(contexts, primary_failure:)
          cleanup_failure = nil
          begin
            Thread.handle_interrupt(Exception => :never) do
              contexts&.each_value do |archive, _verification|
                begin
                  archive.close if archive.respond_to?(:close)
                rescue Exception => error # rubocop:disable Lint/RescueException -- 仍须回收后续资源，保留首个清理故障。
                  cleanup_failure ||= error
                end
              end
            end
          rescue Exception => error # rubocop:disable Lint/RescueException -- 延迟取消不能覆盖原故障或先发生的清理错误。
            cleanup_failure ||= error
          end
          raise cleanup_failure, cause: cleanup_failure.cause if cleanup_failure && !primary_failure
        end

        # 组合配置执行与接口描述操作入口，复用当前清单和接入依赖。
        def operations
          Operations.new(settings: @settings, inventory: method(:inventory), credentials: @credentials,
                         connector_factory: @connector_factory)
        end

        # 策略在清单请求之前固定；注入的清单来源仍由调用方负责其自身生命周期。
        def inventory(settings_snapshot, force_refresh: false)
          @inventory_status = nil
          raise ArgumentError, "force_refresh must be true or false" unless [true, false].include?(force_refresh)

          inventory = @inventory || @settings.inventory(policy: settings_snapshot)
          cache_mode = settings_snapshot.inventory_cache_mode
          raise ArgumentError, "cache-only cannot force refresh" if cache_mode == :only && force_refresh
          if cache_mode == :only && !inventory.is_a?(Inventory::Cache)
            raise Inventory::Error.new("validated inventory cache is unavailable", code: :cache_unavailable), cause: nil
          end
          rows = if inventory.is_a?(Inventory::Cache)
                   inventory.devices(force_refresh: force_refresh, cache_mode: cache_mode)
                 else
                   inventory.devices
                 end
          @inventory_status = if inventory.is_a?(Inventory::Cache)
                                { source: inventory.status, fetched_at: inventory.fetched_at,
                                  refresh_error_code: inventory.refresh_error_code, write_error_type: inventory.write_error_type }.freeze
                              else
                                { source: :uncached }.freeze
                              end
          raise Inventory::Error, "Netdisco returned an invalid device inventory" unless rows.is_a?(Array)

          rules = @rules || settings_snapshot.rules
          devices = rows.map { |row| Device.from_row(row, rules: rules) }
          host_counts = devices.each_with_object(Hash.new(0)) { |device, counts| counts[device.host] += 1 if device.host }
          devices.map { |device| host_counts[device.host] > 1 ? device.with(issue: :duplicate_host) : device }.freeze
        end

        # 在固定清单快照上生成模式对应的计划，规划阶段不读取设备凭据。
        def build_plan(mode, limit, settings_snapshot, allow_fixed_name_reuse: false, force_refresh: false)
          Planner.validate_limit!(limit)
          Planner.new(inventory(settings_snapshot, force_refresh: force_refresh)).call(mode: mode, limit_per_vendor: limit,
                                               allow_fixed_name_reuse: allow_fixed_name_reuse,
                                               tftp_policy: mode == :tftp ? settings_snapshot.tftp_policy : nil)
        end

        # 统一组织设备任务、日志目录与报告；Worker 保证单台设备失败不影响其他设备。
        def run_batch(mode, plan, options:, settings_snapshot:, output_directory: nil)
          Resources.prepare!(parallel: [options.parallel, plan.ready.size].min)
          worker = Worker.new(parallel: options.parallel)
          started_at = Time.now.utc
          started = monotonic
          outcomes = plan.outcomes.dup
          FileUtils.mkdir_p(output_directory, mode: 0o700) if output_directory && !plan.ready.empty?
          log_directory = settings_snapshot.log_directory
          FileUtils.mkdir_p(log_directory, mode: 0o700) if log_directory && !plan.ready.empty?
          worker.run(plan.ready, outcomes: outcomes, on_start: options.on_start, on_result: options.callbacks,
                     on_error: ->(device, error) { build_outcome(device, :failed, error: error) }) do |device|
            yield device, log_directory
          end
          finish_batch(mode, outcomes, worker, options, started_at, started, log_directory)
        rescue Interrupt => interruption
          begin
            # Pool 已停止全部任务；结果组装、发布与保存期间的取消同样保留完成证据。
            Thread.handle_interrupt(Exception => :never) do
              outcomes ||= plan.outcomes.dup
              complete_interrupted_slots(plan, outcomes, worker&.started_tasks || {})
              finish_batch(mode, outcomes, worker, options, started_at || Time.now.utc, started || monotonic,
                           log_directory, interrupted: true)
            end
          rescue Exception # rubocop:disable Lint/RescueException -- 报告故障或二次取消不能替换首个中断。
            nil
          ensure
            raise interruption, cause: interruption.cause
          end
        end

        # 先发布内存回执，再尝试落盘；保存故障不会丢失已经取得的设备结果。
        def finish_batch(mode, outcomes, worker, options, started_at, started, log_directory, interrupted: false)
          batch = Batch.new(mode: mode, outcomes: outcomes.freeze, started_at: started_at,
                            finished_at: Time.now.utc, callback_errors: worker&.callback_errors || [],
                            report_location: nil, report_error: nil, interrupted: interrupted)
          @last_report = Report.new(batch, policy: options.success_policy, duration_ms: ((monotonic - started) * 1000).round,
                                    log_directory: log_directory)
          @last_report = save_report(@last_report, directory: options.report_directory)
        end

        # 中断只补全未交付的槽位；已经确认的备份和上传回执不被取消状态覆盖。
        def complete_interrupted_slots(plan, outcomes, started_tasks)
          plan.ready.each do |index, device|
            next if outcomes[index]

            started_at = started_tasks[index]
            outcomes[index] = Outcome.new(device: device, status: started_at ? :interrupted : :not_started,
                                           backup: nil, error_code: nil, error_type: nil,
                                           started_at: started_at, finished_at: started_at && Time.now.utc)
          end
        end

        # 读取单调时钟秒数，避免系统校时影响期限与耗时计算。
        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # 保存批量报告，记录写入失败而不覆盖设备结果。
        def save_report(report, directory:)
          return report unless @report_store

          report.with(report_location: @report_store.write(report, directory: directory))
        rescue Storage::AtomicFile::WriteError => error
          # 报告也可能已经原子替换；保留已知位置，不将持久性失败误写成完全没有产物。
          location = error.receipt.path if Storage::AtomicFile.receipt_error?(error) && error.receipt.committed?
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

        # 合并显式 TFTP 参数与快照默认值，服务器变化时不借用旧核验目录。
        def tftp_transfer_options(snapshot, **values)
          defaults = { server: :tftp_server, source_files: :tftp_source_files, vrfs: :tftp_vrfs,
                       source_interfaces: :tftp_source_interfaces, servers: :tftp_servers, verification_roots: :tftp_verification_roots }
          defaults.each { |name, method| values[name] = snapshot.public_send(method) if values[name].equal?(DEFAULT_SETTING) }
          if values[:verification_root].equal?(DEFAULT_SETTING)
            same_server = values[:server] && snapshot.tftp_server && values[:server].casecmp?(snapshot.tftp_server)
            values[:verification_root] = same_server ? snapshot.tftp_root : nil
          end
          values
        end

        # 核对计划与实际传输策略一致，预检每台设备的服务器、归档和核验要求。
        def tftp_plan_options(plan, policy, success_policy:, preserve_history:)
          transfers = plan.inventory.select { |device| device.ready? && device.supports_backup?(mode: :tftp) }.to_h do |device|
            [device.host, policy.for(host: device.host, vendor: device.vendor)]
          end
          # 旧调用允许先选设备、执行时再指定服务器；已有服务器和其余策略仍须一致。
          matching = plan.transfers.keys == transfers.keys && plan.transfers.all? do |host, planned|
            actual = transfers.fetch(host)
            expected = planned.server ? planned : planned.with(server: actual.server)
            expected == actual
          end
          unless matching
            raise ArgumentError, "TFTP plan options differ from execution; regenerate the plan"
          end
          plan.selected.each do |device|
            transfer = transfers.fetch(device.host)
            raise ArgumentError, "selected device requires a TFTP server" unless transfer.server
            if Tftp::Root.remote?(transfer.verification_root) && !preserve_history
              raise ArgumentError, "SSH TFTP roots require history archival"
            end
            if plan.allow_fixed_name_reuse && device.vendor == :palo_alto && !transfer.verification_root
              raise ArgumentError, "fixed-name TFTP uploads require a matching server archive directory"
            end
            if success_policy == :verified && !transfer.verification_root
              raise ArgumentError, "verified policy requires a matching TFTP server directory for every selected device"
            end
          end
          if plan.allow_fixed_name_reuse && !preserve_history
            raise ArgumentError, "fixed-name TFTP uploads require local history archival"
          end
          transfers
        end

        # 每台服务器只创建一份归档与核验上下文，再预检最终上传文件名。
        def tftp_contexts(plan, transfers, report_directory:, preserve_history:, parallel:)
          Resources.prepare!(parallel: [parallel, plan.selected.size].min)
          # 每个服务器持有自己的核验/归档上下文，跨服务器设备不能复用全局目录证据。
          groups = plan.selected.group_by { |device| transfers.fetch(device.host).server }
          contexts = groups.to_h do |server, devices|
            transfer = transfers.fetch(devices.first.host)
            if preserve_history
              archive = Tftp::Archive.new(directory: report_directory, root: transfer.verification_root,
                                          ssh_password: @settings.tftp_ssh_password, parallel: [parallel, devices.size].min)
            end
            [server, [archive, Tftp::Verifier.new(root: transfer.verification_root)]]
          end
          validate_tftp_targets!(plan, transfers, contexts)
          contexts
        end

        # 归档批次可能改变远端名；使用最终目标预检协议限制，不能等到读取凭据或发命令后。
        def validate_tftp_targets!(plan, transfers, contexts)
          plan.selected.each do |device|
            transfer = transfers.fetch(device.host)
            archive, = contexts.fetch(transfer.server)
            filename = archive ? archive.upload_filename(device) : device.tftp_filename
            Tftp::Policy.validate_options!(transfer, host: device.host, vendor: device.vendor, path: filename)
          end
        end

        # 执行单台设备的 TFTP 导出。
        def tftp_backup_device(device, transfer, log_directory, settings_snapshot, path: device.tftp_filename)
          run_device(device, log_directory, settings_snapshot, success_status: :reported_uploaded,
                     partial_status: :reported_with_error, backup_class: TftpReceipt) do |connector|
            transfer_settings = { host: transfer.server, path: path, source_file: transfer.source_file }
            transfer_settings[:vrf] = transfer.vrf unless transfer.vrf.nil?
            transfer_settings[:source_interface] = transfer.source_interface unless transfer.source_interface.nil?
            connector.tftp_backup(**transfer_settings)
          end
        end

        # 执行单台设备的本地配置采集。
        def backup_device(device, directory, log_directory, settings_snapshot, filename_style: :ip)
          outcome = nil
          destination = File.join(directory, device.backup_filename(style: filename_style))
          Storage::BackupLock.synchronize(destination, host: device.host) do |path_lock|
            Storage::FileReader.open(destination, missing: true) { |_file, _stat| nil }
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
          access_options = Device::Access.resolve(device, settings: @settings, credentials: @credentials,
                                               policy: settings_snapshot, log_directory: log_directory)
          return build_outcome(device, :missing_credentials) if access_options.nil?
          backup, failure = perform_one(backup_class, factory: -> { @connector_factory.call(device, access_options) }) do |connector|
            operation.call(connector)
          end
          return build_outcome(device, success_status, backup: backup) unless failure

          build_outcome(device, backup ? partial_status : :failed, backup: backup, error: failure)
        rescue StandardError => error
          build_outcome(device, :failed, error: error)
        end

        # 仅信任库定义且产物类型匹配的提交后错误；普通第三方异常上的 backup 字段不代表完成。
        def perform_one(backup_class, factory:)
          backup, failure = Net::Connector::Device::Scope.call(factory: factory) do |session|
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
