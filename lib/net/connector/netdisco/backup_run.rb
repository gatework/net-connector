# frozen_string_literal: true

require "json"
require "socket"

module Net
  module Connector
    module Netdisco
      # 人类批次入口：固定配置、预览、执行、保存报告，最后决定输出与退出码。
      class BackupRun
        def initialize(mode: :backup, argv: ARGV, env: ENV, input: $stdin, output: $stdout, error: $stderr)
          raise ArgumentError, "mode must be backup or tftp" unless %i[backup tftp].include?(mode)

          @mode, @argv, @env, @input, @output, @error = mode, argv, env, input, output, error
        end

        def run
          options = CLI::Options.parse(argv: @argv, input: @input, output: @output, error: @error)
          return 0 if options[:help]

          settings, success_policy, server_root, batch_directory = prepare(options)
          client, credentials = Connection.build(settings, stdin_credentials: options[:stdin_credentials], input: @input)
          progress = Progress.new(io: @error, enabled: @env.fetch("NC_PROGRESS", "1") != "0", verbose: options[:verbose])
          resolver = ->(device) { credentials.call(device)&.merge(on_event: progress.method(:event)) }
          fleet = Fleet.new(client: client, settings: settings, credentials: resolver, result_store: nil)
          progress.reading_inventory
          limit = settings.limit_per_vendor
          plan = if @mode == :backup
                   fleet.plan_backup(limit_per_vendor: limit)
                 else
                   fleet.plan_tftp_backup(limit_per_vendor: limit, allow_fixed_name_reuse: !server_root.nil?)
                 end
          progress.plan(plan, concurrency: settings.concurrency, limit_per_vendor: limit)
          preview = plan_summary(plan)
          @output.puts JSON.generate(plan: preview) if options[:json]
          @output.flush
          return 1 if options[:stdin_credentials] && @input.gets&.strip != "RUN"

          Storage::PrivateFile.write(File.join(batch_directory, "plan.json"), JSON.pretty_generate(preview))
          report = execute(fleet, settings, plan, batch_directory, progress, success_policy, server_root)
          report = Report::Files.write(report, directory: batch_directory, plan: plan, concurrency: settings.concurrency)
          finish(report, progress, options, batch_directory)
        rescue ArgumentError, Client::Error => exception
          @error.puts "备份参数或清单错误：#{exception.message}"
          2
        rescue StandardError => exception
          @error.puts "备份未完成（#{exception.class}）"
          2
        end

        private

        def prepare(options)
          settings = CLI::Options.settings(options, env: @env)
          success_policy = options.fetch(:success_policy, :selected)
          raise ArgumentError, "verified policy requires TFTP mode" if success_policy == :verified && @mode != :tftp
          raise ArgumentError, "--tftp-root requires TFTP mode" if options[:tftp_root] && @mode != :tftp
          server_root = tftp_root(settings, options) if @mode == :tftp
          raise ArgumentError, "verified policy requires a local TFTP directory" if success_policy == :verified && !server_root
          TftpVerification.new(root: server_root) if server_root
          batch_directory = Storage::BatchDirectory.create(settings.backup_directory)
          if @mode == :tftp && !settings.log_directory
            settings = settings.with_overrides("NC_LOG_DIRECTORY" => File.join(batch_directory, "logs"))
          end
          settings = settings.for_run(mode: @mode)
          [settings, success_policy, server_root, batch_directory]
        end

        def execute(fleet, settings, plan, batch_directory, progress, success_policy, server_root)
          File.open(File.join(batch_directory, "events.jsonl"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |events|
            options = { plan: plan, concurrency: settings.concurrency, success_policy: success_policy,
                        on_start: progress.method(:start), on_result: result_callback(progress, events) }
            progress.with_updates do
              if @mode == :backup
                fleet.backup_all(directory: batch_directory, filename_style: :hostname_ip, **options)
              else
                fleet.tftp_backup_all(server: settings.tftp_server, source_files: settings.tftp_source_files,
                                      vrfs: settings.tftp_vrfs, report_directory: batch_directory,
                                      verification_root: server_root, preserve_history: true, **options)
              end
            end
          end
        end

        def result_callback(progress, events)
          lock = Mutex.new
          lambda do |outcome|
            progress.result(outcome)
            lock.synchronize do
              events.puts JSON.generate(host: outcome.device.host, vendor: outcome.device.vendor,
                                         status: outcome.status, error_code: outcome.diagnostic&.error_code,
                                         error_type: outcome.diagnostic&.error_type, duration_ms: outcome.duration_ms)
              events.flush
            end
          end
        end

        def finish(report, progress, options, batch_directory)
          progress.finish(report)
          progress.location(report.report_location) if report.report_location
          @error.puts "文本报告：#{File.join(batch_directory, "summary.txt")}" if @env.fetch("NC_PROGRESS", "1") != "0" && File.file?(File.join(batch_directory, "summary.txt"))
          if options[:json]
            @output.puts JSON.generate(directory: batch_directory, counts: report.counts,
                                       tasks_succeeded: report.policy_success?, success: report.policy_success?,
                                       policy: report.policy, policy_success: report.policy_success?,
                                       report_location: report.report_location, report_error: report.report_error)
          end
          report.policy_success? ? 0 : 1
        end

        def tftp_root(settings, options)
          server = settings.tftp_server || (raise ArgumentError, "TFTP_HOST or YAML tftp.server is required")
          return options[:tftp_root] || @env["TFTP_ROOT"] if options[:tftp_root] || @env["TFTP_ROOT"]
          return unless Socket.ip_address_list.any? { |address| address.ip_address == server }

          candidate = File.join(Dir.home, "Documents", "TFTP")
          candidate if File.directory?(candidate)
        end

        def plan_summary(plan)
          { total: plan.inventory.size, ready: plan.inventory.count(&:ready?),
            vendors: plan.inventory.group_by { |device| device.vendor || :unmapped }.transform_values(&:size),
            issues: plan.inventory.reject(&:ready?).group_by(&:issue).transform_values(&:size),
            selected: plan.selected.map do |device|
              filename = @mode == :backup ? device.backup_filename(style: :hostname_ip) : device.tftp_filename
              { host: device.host, name: device.name, vendor: device.vendor, backup_filename: filename }
            end }
        end
      end
    end
  end
end
