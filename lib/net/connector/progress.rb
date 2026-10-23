# frozen_string_literal: true

require "io/console"
require_relative "engine/error/metadata"
require_relative "engine/log/event"
require_relative "parallel/observer"

module Net
  module Connector
    # 共享终端、阶段与心跳机制；领域结果由各入口适配，进度始终写入独立 IO。
    class Progress
      # 读取首次终端输出故障的受控诊断，供最终报告保留。
      attr_reader :output_error

      # 调用方保留输出 IO 所有权；同一个互斥锁保护心跳、事件和任务计数。
      def initialize(io: $stderr, enabled: true, verbose: false)
        @io, @enabled, @verbose = io, enabled, verbose
        @tty = io.respond_to?(:tty?) && io.tty?
        @stages = {}
        @task_started = {}
        @failures = Hash.new(0)
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @succeeded = @failed = 0
        @mutex = Mutex.new
        @total = @completed = @active = 0
      end

      # 输出当前开始读取清单的进度提示。
      def reading_inventory(config: nil)
        write(nil, "Reading Netdisco device inventory#{config ? "(configuration: #{config})" : ""}")
      end

      # 以实际选中设备初始化进度，跳过的条目不计入执行任务总数。
      def plan(total:, selected:, parallel:, label: "all devices")
        @mutex.synchronize do
          @total = selected
          @completed = @active = 0
          @run_started = monotonic
          emit(nil, "#{label} | Inventory #{total} devices; selected #{@total}; skipped #{total - @total} devices; concurrency #{parallel}")
        end
      end

      # 任务开始只表示进入登录阶段，不代表设备已连接。
      def start(host:, label: "collecting")
        @mutex.synchronize do
          @active += 1
          @stages[host] = "logging in"
          @task_started[host] = monotonic
          @verbose ? emit(host, "starting#{label}") : refresh
        end
      end

      # 领域适配器传入安全状态文案；成功设备默认只参与批次计数。
      def result(host:, success:, duration_ms:, message:, error_code: nil)
        @mutex.synchronize do
          @completed += 1
          @active -= 1
          @stages.delete(host)
          @task_started.delete(host)
          success ? @succeeded += 1 : @failed += 1
          hint = failure_hint(error_code)
          message = "#{message}; #{hint}" if hint
          if @verbose || !success
            emit(host, "#{message}; elapsed #{duration_ms} ms")
          elsif !@tty && ((@completed % 25).zero? || @completed == @total)
            emit(nil, status_line)
          end
          refresh
        end
      end

      # 完成百分比只表示任务结束，最终结果始终由已保存的业务报告决定。
      def finish(success:, succeeded:, partial:, failed:, skipped:, failures: {})
        unless failures.empty?
          write(nil, "Incomplete categories: #{failures.sort_by { |code, count| [-count, code.to_s] }.map { |code, count| "#{code}=#{count}" }.join(", ")}")
        end
        write(nil, "Batch finished: succeeded #{succeeded}, partial #{partial}, failed #{failed}, skipped #{skipped}; elapsed #{(monotonic - @started_at).round(1)} seconds; result #{success ? "complete" : "incomplete"}")
      end

      # 普通批次提示也复用锁、脱敏和输出故障处理。
      def notice(message)
        write(nil, message)
      end

      # 只显示已脱敏事件中的阶段和安全命令，不显示设备回显或异常原文。
      def event(event)
        return unless event.is_a?(Log::Event)

        unless @verbose
          @mutex.synchronize do
            host = event.fields[:host]
            @stages[host] = "collecting" if @stages.key?(host) && event.name == "login_complete" && event.fields[:status] == "ok"
            refresh
          end
          return
        end

        fields = event.fields
        message = case event.name
                  when "connect" then "Connecting and logging in (#{fields[:protocol]})"
                  when "login_complete"
                    fields[:status] == "ok" ? "Login succeeded" : "Login failed (#{fields[:code]})"
                  when "connect_failed" then "Connection failed (#{fields[:code]})"
                  when "command_start" then "Executing command: #{fields[:text]}; waiting for response"
                  when "command_complete"
                    fields[:status] == "response_received" ? "Command response complete (#{fields[:duration_ms]} ms)" :
                      "Command failed (#{fields[:code]})"
                  when "operation_complete"
                    fields[:status] == "completed" ? "Script complete" : "Script failed (#{fields[:code]})"
                  end
        write(fields[:host], message) if message
      end

      # 心跳只负责显示；退出、异常或中断时先唤醒并回收线程。
      def with_updates(&)
        return yield unless @enabled && @tty && !@verbose

        lock = Mutex.new
        signal = ConditionVariable.new
        stopped = false
        task = lambda do
          loop do
            stop = lock.synchronize do
              signal.wait(lock, 1) unless stopped
              stopped
            end
            break if stop

            tick
          end
        rescue StandardError => error
          # 非 IO 的显示故障也只停用进度；完整报告仍记录这一受控诊断。
          @mutex.synchronize { record_output_error(error) }
        end
        stop = -> { lock.synchronize { stopped = true; signal.broadcast } }
        Parallel::Observer.run(task: task, stop: stop, &)
      rescue Exception => error # rubocop:disable Lint/RescueException -- 后台已回收，最后清屏也不能覆盖原业务故障或取消。
        primary_failure = error
        raise
      ensure
        begin
          Thread.handle_interrupt(Exception => :never) { @mutex.synchronize { clear_refresh } if task }
        rescue Exception => error # rubocop:disable Lint/RescueException -- 清屏中的取消正常传播，已有主故障时保持其身份。
          raise error unless primary_failure
        end
      end

      # 心跳仅在持锁后刷新显示，不改变设备任务或完成计数。
      def tick
        @mutex.synchronize { refresh(force: true) }
      end

      # 显示已保存报告的位置与可读标签。
      def location(path, label: "report")
        write(nil, "#{label}: #{path}")
      end

      private

      # 根据已知错误码返回简短排查建议，不展示任意异常正文。
      def failure_hint(code)
        case code
        when :authentication_failed then "Device rejected authentication; check username, password or AAA policy"
        when :authentication_error then "Authentication dialogue incomplete; check authentication method or device AAA logs"
        when :host_key_untrusted then "Host key is not yet trusted; verify and register its fingerprint"
        when :host_key_changed then "Registered host key changed; verify device identity"
        when :login_timeout then "Login prompt not received before the deadline; check SSH handshake and login dialogue"
        when :connection_timeout then "SSH connection or handshake timed out; check service and network"
        when :device_error then "Device rejected the command; check vendor mapping and account permissions"
        when :missing_completeness_evidence then "Completeness evidence missing; see the device report for incomplete dimensions"
        when :report_not_saved then "Device report persistence unconfirmed"
        end
      end

      # 生成已完成、成功、失败、当前阶段和排队数量摘要。
      def status_line
        percent = @total.positive? ? @completed * 100 / @total : 0
        counts = progress_counts
        "#{@completed}/#{@total} #{percent}% | #{counts} | Logging in #{@stages.values.count("logging in")} collecting #{@stages.values.count("collecting")} queued #{[@total - @completed - @active, 0].max}"
      end

      # 默认统计设备任务，领域适配器可提供自己的计数文案。
      def progress_counts = "succeeded #{@succeeded} incomplete #{@failed}"

      # 读取单调时钟秒数，避免系统校时影响期限与耗时计算。
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # 将秒数格式化为小时、分钟和秒。
      def duration(seconds)
        total = seconds.round
        format("%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
      end

      # 吞吐与预计剩余时间使用单调时钟；异构设备的估算不能视为任务期限。
      def timing_line
        elapsed = [monotonic - (@run_started || @started_at), 0].max
        rate = elapsed.positive? ? @completed / elapsed : 0
        eta = if @completed == @total && @total.positive?
                "00:00:00"
              elsif @completed >= 5 && rate.positive?
                "about #{duration((@total - @completed) / rate)}"
              else
                "estimating"
              end
        line = "elapsed #{duration(elapsed)} | #{format("%.1f", rate)} devices/s | remaining #{eta}"
        host, started = @task_started.min_by { |_key, value| value }
        if started && monotonic - started >= 10
          line += " | longest #{host} #{@stages[host]} #{(monotonic - started).floor}s"
        end
        line
      end

      # TTY 原地刷新最多每秒五次；详细事件和重定向输出采用独立显示路径。
      def refresh(force: false)
        return unless @enabled && @tty && !@verbose

        now = monotonic
        return if !force && @refreshing && @completed < @total && @last_refresh && now - @last_refresh < 0.2

        @last_refresh = now
        divider = fit_terminal("-" * 100)
        lines = [divider, fit_terminal(status_line), fit_terminal(timing_line), divider]
        return if @refreshing && @last_status == lines

        clear_refresh
        @last_status = lines
        @refreshing = write_output(lines.join("\n"))
      end

      # 留一列避免终端自动换行，窄窗口也不会留下旧进度行。
      def fit_terminal(line)
        columns = @io.respond_to?(:winsize) ? @io.winsize.last : 120
        columns = 120 unless columns.positive?
        width = 0
        text = line.gsub(/[[:cntrl:]]/, " ")
        text.each_char.take_while do |character|
          width += character.ord > 255 ? 2 : 1
          width < columns
        end.join("")
      rescue IOError, SystemCallError
        line
      end

      # 擦除前一次实际显示的行数，避免短文本或窄终端留下旧状态。
      def clear_refresh
        return unless @refreshing

        write_output("\r\e[2K" + ("\e[1A\r\e[2K" * (@last_status.length - 1)))
        @refreshing = false
      end

      # 在进度互斥锁内输出一条消息，避免多线程交错刷新。
      def write(host, message)
        @mutex.synchronize { emit(host, message) }
      end

      # 清除旧进度后输出经过控制符过滤的单行消息。
      def emit(host, message)
        return unless @enabled

        percent = @total.positive? ? " #{(@completed * 100.0 / @total).floor}%" : ""
        clear_refresh
        line = "[#{Time.now.strftime("%H:%M:%S")}] [#{@completed}/#{@total}#{percent} running #{@active}] [#{host || "batch"}] #{message}"
        line = "[#{Time.now.strftime("%H:%M:%S")}] #{host ? "#{host}  " : ""}#{message}" unless @verbose
        write_output(line.gsub(/[[:cntrl:]]/, " ") + "\n")
      end

      # 显示失败只停用进度输出；批次仍保存回执和事件，并记录一次受控回调诊断。
      # 所有调用均持有 @mutex，心跳与设备线程不会重复访问已失败的输出。
      def write_output(text)
        return false unless @enabled

        @io.write(text)
        @io.flush
        true
      rescue StandardError => error
        record_output_error(error)
        false
      end

      # 保存一次受控输出错误并停用进度，设备任务仍继续保存结果。
      def record_output_error(error)
        @output_error = { host: nil, error_type: Error::Metadata.type(error.class.name) || "StandardError" }.freeze
        @enabled = false
      end
    end
  end
end
