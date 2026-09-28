# frozen_string_literal: true

require "io/console"

module Net
  module Connector
    module Netdisco
      # 共享一个实例接收并发会话事件和任务回调；人类进度不混入 JSON 输出。
      class Progress
        def initialize(io: $stderr, enabled: true, verbose: false)
          @io, @enabled, @verbose = io, enabled, verbose
          @tty = io.respond_to?(:tty?) && io.tty?
          @stages = {}
          @task_started = {}
          @failures = Hash.new(0)
          @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @succeeded = @failed = @unverified = 0
          @mutex = Mutex.new
          @total = @completed = @active = 0
        end

        def reading_inventory
          write(nil, "正在读取 Netdisco 设备清单")
        end

        def plan(plan, concurrency:, limit_per_vendor: nil)
          @mutex.synchronize do
            @total = plan.ready.size
            @completed = @active = 0
            @run_started = monotonic
            mode = limit_per_vendor ? "抽样（每厂商最多 #{limit_per_vendor} 台）" : "全量"
            emit(nil, "#{mode} | 清单 #{plan.inventory.size} 台；本次 #{@total} 台；跳过 #{plan.inventory.size - @total} 台；并发 #{concurrency}")
          end
        end

        def start(device)
          @mutex.synchronize do
            @active += 1
            @stages[device.host] = "登录"
            @task_started[device.host] = monotonic
            @verbose ? emit(device.host, "开始备份（#{device.vendor}）") : refresh
          end
        end

        # 只显示已脱敏事件中的阶段和安全命令，不显示设备回显或异常原文。
        def event(event)
          return unless event.is_a?(Log::Event)

          unless @verbose
            @mutex.synchronize do
              host = event.fields[:host]
              @stages[host] = "采集" if @stages.key?(host) && event.name == "login_complete" && event.fields[:status] == "ok"
              refresh
            end
            return
          end

          fields = event.fields
          message = case event.name
                    when "connect" then "正在连接并登录（#{fields[:protocol]}）"
                    when "login_complete"
                      fields[:status] == "ok" ? "登录成功" : "登录失败（#{fields[:code]}）"
                    when "connect_failed" then "连接失败（#{fields[:code]}）"
                    when "command_start" then "执行命令：#{fields[:text]}；等待响应"
                    when "command_complete"
                      fields[:status] == "response_received" ? "命令响应完成（#{fields[:duration_ms]} ms）" :
                        "命令失败（#{fields[:code]}）"
                    when "operation_complete"
                      fields[:status] == "completed" ? "脚本处理完成" : "脚本处理失败（#{fields[:code]}）"
                    end
          write(fields[:host], message) if message
        end

        def result(outcome)
          @mutex.synchronize do
            @completed += 1
            @active -= 1
            @stages.delete(outcome.device.host)
            @task_started.delete(outcome.device.host)
            @failures[outcome.error_code || outcome.status] += 1 unless outcome.success?
            outcome.success? ? @succeeded += 1 : @failed += 1
            @unverified += 1 if outcome.status == :reported_uploaded && outcome.backup&.verification != :server_verified
            message = case outcome.status
                      when :backed_up then "备份已保存（#{outcome.backup.bytes} 字节）"
                      when :reported_uploaded
                        outcome.backup&.verification == :server_verified ? "配置已归档（#{outcome.backup.server_bytes} 字节）" :
                          "设备报告上传完成；服务器文件尚未核验"
                      when :saved_with_error then "备份有产物但未完全成功（#{outcome.error_code}）"
                      when :reported_with_error then "设备报告上传但收尾异常（#{outcome.error_code}）"
                      else "未完成（#{outcome.error_code || outcome.status}）"
                      end
            hint = failure_hint(outcome.error_code)
            message = "#{message}；#{hint}" if hint
            if @verbose || !outcome.success?
              emit(outcome.device.host, "#{message}；耗时 #{outcome.duration_ms} ms")
            elsif !@tty && ((@completed % 25).zero? || @completed == @total)
              emit(nil, status_line)
            end
            refresh
          end
        end

        def finish(report)
          summary = report.summary
          failures = report.outcomes.reject { |item| item.success? || %i[filtered sample_limit].include?(item.status) }
                           .group_by { |item| item.error_code || item.status }.transform_values(&:size)
          unless failures.empty?
            write(nil, "未完成分类：#{failures.sort_by { |code, count| [-count, code.to_s] }.map { |code, count| "#{code}=#{count}" }.join("，")}")
          end
          write(nil, "批次结束：成功 #{summary[:succeeded]}，部分成功 #{summary[:partial]}，失败 #{summary[:failed]}，跳过 #{summary[:skipped]}；耗时 #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at).round(1)} 秒；结果 #{report.policy_success? ? "完成" : "未完成"}")
          unverified = summary[:verification]&.fetch(:unverified, 0) || 0
          write(nil, "其中 #{unverified} 台仅设备报告上传完成，服务器文件尚未核验") if unverified.positive?
          return unless !report.callback_errors.empty? || report.report_error

          write(nil, "回调异常 #{report.callback_errors.size}，报告错误 #{report.report_error || "无"}")
        end

        # 心跳只负责显示；退出、异常或中断时先唤醒并回收线程。
        def with_updates
          return yield unless @enabled && @tty && !@verbose

          lock = Mutex.new
          signal = ConditionVariable.new
          stopped = false
          worker = Thread.new do
            loop do
              stop = lock.synchronize do
                signal.wait(lock, 1) unless stopped
                stopped
              end
              break if stop

              tick
            end
          end
          yield
        ensure
          if worker
            lock.synchronize { stopped = true; signal.broadcast }
            worker.value
            @mutex.synchronize { clear_refresh }
          end
        end

        def tick
          @mutex.synchronize { refresh(force: true) }
        end

        def location(path)
          write(nil, "报告：#{path}")
        end

        private

        def failure_hint(code)
          case code
          when :authentication_failed then "设备拒绝认证，请核对账号、密码或 AAA 策略"
          when :authentication_error then "认证交互未完成，请核对认证方式或设备 AAA 日志"
          when :host_key_untrusted then "主机密钥尚未信任，请确认指纹并登记"
          when :host_key_changed then "已登记主机密钥发生变化，请核实设备身份"
          when :login_timeout then "未在期限内获得登录提示，请检查 SSH 握手与登录交互"
          when :connection_timeout then "SSH 连接或握手超时，请检查服务与网络"
          when :device_error then "设备拒绝命令，请核对厂商映射和账号权限"
          end
        end

        def status_line
          percent = @total.positive? ? @completed * 100 / @total : 0
          "#{@completed}/#{@total} #{percent}% | 成功 #{@succeeded} 未完成 #{@failed} | 登录 #{@stages.values.count("登录")} 采集 #{@stages.values.count("采集")} 排队 #{[@total - @completed - @active, 0].max}"
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def duration(seconds)
          total = seconds.round
          format("%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        end

        def timing_line
          elapsed = [monotonic - (@run_started || @started_at), 0].max
          rate = elapsed.positive? ? @completed / elapsed : 0
          eta = if @completed == @total && @total.positive?
                  "00:00:00"
                elsif @completed >= 5 && rate.positive?
                  "约 #{duration((@total - @completed) / rate)}"
                else
                  "估算中"
                end
          line = "耗时 #{duration(elapsed)} | #{format("%.1f", rate)} 台/秒 | 剩余 #{eta}"
          host, started = @task_started.min_by { |_key, value| value }
          if started && monotonic - started >= 10
            line += " | 最久 #{host} #{@stages[host]} #{(monotonic - started).floor}s"
          end
          line
        end

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
          @io.write(lines.join("\n"))
          @io.flush
          @refreshing = true
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
          end.join
        rescue IOError, SystemCallError
          line
        end

        def clear_refresh
          return unless @refreshing

          @io.write("\r\e[2K" + ("\e[1A\r\e[2K" * (@last_status.length - 1)))
          @refreshing = false
        end

        def write(host, message)
          @mutex.synchronize { emit(host, message) }
        end

        def emit(host, message)
          return unless @enabled

          percent = @total.positive? ? " #{(@completed * 100.0 / @total).floor}%" : ""
          clear_refresh
          line = "[#{Time.now.strftime("%H:%M:%S")}] [#{@completed}/#{@total}#{percent} 执行中 #{@active}] [#{host || "批次"}] #{message}"
          line = "[#{Time.now.strftime("%H:%M:%S")}] #{host ? "#{host}  " : ""}#{message}" unless @verbose
          @io.write(line.gsub(/[[:cntrl:]]/, " ") + "\n")
          @io.flush
        end
      end
    end
  end
end
