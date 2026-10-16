# frozen_string_literal: true

require "open3"
require "expect/pty"
require_relative "known_hosts"

module Net
  module Connector
    # 传输事件使用从零开始的模式索引；最后一个额外索引表示流式数据。
    Event = Struct.new(:index, :before, :match, :error) do
      # 固定每次读取的字节快照，传输复用缓冲区时不能改写先前分片。
      def initialize(index: nil, before: "".b, match: "".b, error: nil)
        unless before.is_a?(String) && match.is_a?(String)
          raise ArgumentError, "before and match must be Strings"
        end

        before = before.b.freeze unless before.frozen? && before.encoding == Encoding::BINARY
        match = match.b.freeze unless match.frozen? && match.encoding == Encoding::BINARY
        super(index, before, match, error)
        freeze
      end

      # 判断读取是否命中了模式而不是传输错误。
      def matched? = error.nil?

      # 返回事件索引和错误类型摘要。
      def inspect = "#<#{self.class} index=#{index.inspect} error=#{error&.class}>"
    end

    # 可替换的字节传输层；厂商语法属于设备边界，不属于此层。
    module Transports
      # Expect 适配器拥有伪终端和进程，在限制未匹配尾部时不丢弃数据。
      class Pty
        # 即使读到完整行也保留 32 KiB，因为提示符可能跨越多次读取和多行。
        STREAM = /\A[\s\S]{32768}(?=[\s\S]{32768})/n
        attr_reader :configuration

        # 保存配置和可替换的信道工厂，便于测试和设备差异注入。
        def initialize(configuration, channel_factory: nil, terminal_size: nil)
          @configuration = configuration
          @channel_factory = channel_factory
          @terminal_size = terminal_size
        end

        # 打开伪终端、设置终端大小并启动设备进程。
        def open
          failure = nil
          configuration.validate_endpoint!
          # 构造期间的阻塞仍可取消；返回交接先登记信道，再交付异步中断。
          Thread.handle_interrupt(Exception => :on_blocking) do
            @channel = if @channel_factory
                         @channel_factory.call
                       elsif defined?(Expect::Session)
                         Expect::Session.new(buffer_limit: nil, write_timeout: configuration.write_timeout)
                       else
                         Expect.new(raw_pty: true, reset_timeout_on_read: false, buffer_limit: nil,
                                    preserve_buffer: false, log_stdout: false, log_listeners: false,
                                    debug_level: 0, write_timeout: configuration.write_timeout)
                       end
          rescue Exception => error # rubocop:disable Lint/RescueException -- 退出屏蔽范围交付取消之前，先保存构造器的同步故障。
            failure = error
            raise
          end
          # Profile 使用宽、高；PTY 使用行数、列数。
          @channel.slave.winsize = @terminal_size.reverse if @terminal_size
          if @channel.respond_to?(:transcript=)
            writer = Object.new
            callback = method(:write_log_output)
            writer.define_singleton_method(:write) do |bytes|
              callback.call(bytes)
              bytes.bytesize
            end
            @channel.transcript = writer
            @channel.spawn(*argv, raw: true)
          else
            @channel.log_output = method(:write_log_output)
            @channel.spawn(*argv)
          end
          self
        rescue Exception => error # rubocop:disable Lint/RescueException -- 中断时也必须释放尚未完成初始化的 PTY。
          close_preserving_failure
          raise failure || error, cause: nil
        end

        # 从信道读取下一事件，并把字符串字段转换为字节字符串。
        def read(patterns, timeout:)
          reader = @channel.respond_to?(:expect_result) ? :expect_result : :expect
          result = @channel.public_send(reader, *patterns, STREAM, timeout: timeout)
          Event.new(index: result.number && (result.number - 1), before: result.before.to_s,
                    match: result.match.to_s, error: result.error)
        end

        # 临时设置写入超时，完成写入后恢复原设置。
        def write(bytes, timeout: configuration.write_timeout)
          channel = @channel
          previous = channel.write_timeout
          begin
            channel.write_timeout = timeout
            channel.write(bytes)
          rescue Exception # rubocop:disable Lint/RescueException -- 恢复超时前保留写入的首个故障或中断。
            failed = true
            raise
          ensure
            begin
              channel.write_timeout = previous
            rescue Exception # rubocop:disable Lint/RescueException -- 收尾故障不能把中断转换成普通写入错误。
              raise unless failed
            end
          end
        end

        # 判断信道尚未建立或已经关闭。
        def closed? = !@channel || @channel.closed?

        # 设置日志输出目标；nil 表示暂时停止记录。
        def log_output=(target)
          @log_target = target
        end

        # 清除信道和日志目标，并强制关闭底层进程。
        def close
          failure = nil
          # 从字段移交到关闭完成期间不能取消，避免丢失尚未回收的进程。
          Thread.handle_interrupt(Exception => :never) do
            channel = @channel
            @channel = nil
            @log_target = nil
            channel&.hard_close
          rescue Exception => error # rubocop:disable Lint/RescueException -- 延迟取消不能覆盖底层关闭的首个故障。
            failure = error
            raise
          end
        rescue Exception => error # rubocop:disable Lint/RescueException -- 恢复取消交付时仍保留最先观察到的故障。
          raise failure || error, cause: nil
        end

        # 把人工交互结果转换为设备 EOF、超时或输入状态。
        def interact(**)
          stopped = @channel.interact(**)
          return :device_eof if stopped.equal?(@channel)

          stopped.nil? ? :timeout : :input
        end

        # 返回传输主机和关闭状态摘要。
        def inspect = "#<#{self.class} host=#{configuration.host.inspect} closed=#{closed?}>"

        private

        # 已有操作异常时仍尝试清理；次级故障或中断不能覆盖原始失败。
        def close_preserving_failure
          close
        rescue Exception # rubocop:disable Lint/RescueException -- 清理后继续传播原始操作异常。
          nil
        end

        # 检查缓冲上限并把设备输出写入当前日志目标。
        def write_log_output(bytes)
          if @channel.buffer.bytesize > configuration.max_output_bytes
            raise OutputLimitExceeded.new("transport buffer exceeded max_output_bytes",
                                          phase: :read, output: @channel.buffer.dup), cause: nil
          end

          @log_target&.write(bytes)
          @log_target.flush if @log_target.respond_to?(:flush)
        end
      end

      # 生成 OpenSSH 参数，并处理显式请求的旧版协商和主机密钥操作。
      class Ssh < Pty
        attr_reader :legacy_arguments

        # 保存旧版 SSH 参数并复用伪终端初始化。
        def initialize(configuration, legacy_arguments: [], **)
          super(configuration, **)
          @legacy_arguments = legacy_arguments.dup.freeze
        end

        def open
          failure = nil
          configuration.validate_endpoint!
          unless configuration.host_key_policy == :strict
            # 临时信任文件的返回交接与信道遵守同一所有权边界。
            Thread.handle_interrupt(Exception => :on_blocking) do
              @known_hosts = KnownHosts.new(configuration, replace: @replace_host_key)
            rescue Exception => error # rubocop:disable Lint/RescueException -- 构造器先失败时，延迟取消不得覆盖其原始异常。
              failure = error
              raise
            end
          end
          super
        rescue Exception => error # rubocop:disable Lint/RescueException -- 启动失败或中断时释放临时信任文件。
          close_preserving_failure
          raise failure || error, cause: nil
        end

        def authenticated
          @known_hosts&.commit
          @replace_host_key = false
        end

        def close
          failure = nil
          # 一次取消须等待信道和信任快照均完成回收；同步故障仍保留首个。
          Thread.handle_interrupt(Exception => :never) do
            known_hosts = @known_hosts
            @known_hosts = nil
            begin
              super
            rescue Exception => error # rubocop:disable Lint/RescueException -- 全部资源均须尝试关闭，保留首个失败或中断。
              failure = error
              raise
            ensure
              begin
                known_hosts&.close
              rescue Exception => error # rubocop:disable Lint/RescueException -- 信任文件收尾不能覆盖传输关闭的原始异常。
                unless failure
                  failure = error
                  raise
                end
              end
            end
          end
        rescue Exception => error # rubocop:disable Lint/RescueException -- 恢复取消交付也不能盖掉已经发生的关闭故障。
          raise failure || error, cause: nil
        end

        # 返回 SSH 协议标识。
        def protocol = :ssh

        # 根据配置生成经过端点校验的 SSH 参数数组。
        def argv
          configuration.validate_endpoint!
          checking = (configuration.host_key_policy == :strict) ? "yes" : "accept-new"
          arguments = ["ssh", *legacy_arguments, "-tt", "-o", "StrictHostKeyChecking=#{checking}",
                       "-o", "NumberOfPasswordPrompts=1", "-o", "UpdateHostKeys=no",
                       "-o", "ConnectTimeout=#{[configuration.login_timeout.ceil, 1].max}"]
          known_hosts = @known_hosts&.path || configuration.known_hosts
          arguments += ["-o", "UserKnownHostsFile=#{known_hosts}"] if known_hosts
          arguments += ["-p", configuration.port.to_s] if configuration.port
          arguments + ["-l", configuration.username, configuration.host]
        end

        # 创建带旧版协商参数的同类传输对象。
        def with_legacy(arguments)
          self.class.new(configuration, legacy_arguments: arguments, channel_factory: @channel_factory,
                         terminal_size: @terminal_size)
        end

        # 创建不继承 SSH 专用端口的 Telnet 传输对象。
        def as_telnet
          Telnet.new(configuration, channel_factory: @channel_factory, terminal_size: @terminal_size)
        end

        # 恢复只标记下一次会话副本；共享信任文件在认证成功后才更新。
        def replace_host_key
          raise IOError, "host key replacement is not enabled" unless configuration.host_key_policy == :replace

          @replace_host_key = true
        end

      end

      # Telnet 只能显式启用；SSH 专用端口不能带入回退连接。
      class Telnet < Pty
        # 返回 Telnet 协议标识。
        def protocol = :telnet

        # 根据配置生成经过端点校验的 Telnet 参数数组。
        def argv
          configuration.validate_endpoint!
          port = (configuration.protocol == :telnet) ? configuration.port : nil
          ["telnet", "-l", configuration.username, configuration.host, *(port ? [port.to_s] : [])]
        end
      end

      TYPES = { ssh: Ssh, telnet: Telnet }.freeze

      # 按协议选择具体传输实现。
      def self.build(configuration, **)
        TYPES.fetch(configuration.protocol).new(configuration, **)
      end
    end
  end
end
