# frozen_string_literal: true

require "open3"
require "expect/pty"

module Net
  module Connector
    # 传输事件使用从零开始的模式索引；最后一个额外索引表示流式数据。
    Event = Struct.new(:index, :before, :match, :error) do
      # 规范化事件的默认字节字段，便于读取器统一处理。
      def initialize(index: nil, before: "".b, match: "".b, error: nil)
        super
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
          configuration.validate_endpoint!
          @channel = if @channel_factory
                       @channel_factory.call
                     else
                       Expect.new(raw_pty: true, reset_timeout_on_read: false, buffer_limit: nil,
                                  preserve_buffer: false, log_stdout: false, log_listeners: false,
                                  debug_level: 0, write_timeout: configuration.write_timeout)
                     end
          # Profile 使用宽、高；PTY 使用行数、列数。
          @channel.slave.winsize = @terminal_size.reverse if @terminal_size
          @channel.log_output = method(:write_log_output)
          @channel.spawn(*argv)
          self
        rescue Exception # rubocop:disable Lint/RescueException -- A half-open PTY must be released on interrupts.
          begin
            close
          rescue
            # 尝试释放半打开信道后，仍然抛出原始失败。
          end
          raise
        end

        # 从信道读取下一事件，并把字符串字段转换为字节字符串。
        def read(patterns, timeout:)
          result = @channel.expect_result(*patterns, STREAM, timeout: timeout)
          Event.new(index: result.number && (result.number - 1), before: result.before.to_s.b,
                    match: result.match.to_s.b, error: result.error)
        end

        # 临时设置写入超时，完成写入后恢复原设置。
        def write(bytes, timeout: configuration.write_timeout)
          previous = @channel.write_timeout
          @channel.write_timeout = timeout
          @channel.write(bytes)
        ensure
          @channel.write_timeout = previous if @channel
        end

        # 判断信道尚未建立或已经关闭。
        def closed? = !@channel || @channel.closed?

        # 设置日志输出目标；nil 表示暂时停止记录。
        def log_output=(target)
          @log_target = target
        end

        # 清除信道和日志目标，并强制关闭底层进程。
        def close
          channel = @channel
          @channel = nil
          @log_target = nil
          channel&.hard_close
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

        # 返回 SSH 协议标识。
        def protocol = :ssh

        # 根据配置生成经过端点校验的 SSH 参数数组。
        def argv
          configuration.validate_endpoint!
          checking = (configuration.host_key_policy == :strict) ? "yes" : "accept-new"
          arguments = ["ssh", *legacy_arguments, "-tt", "-o", "StrictHostKeyChecking=#{checking}",
                       "-o", "NumberOfPasswordPrompts=1",
                       "-o", "ConnectTimeout=#{[configuration.login_timeout.ceil, 1].max}"]
          arguments += ["-o", "UserKnownHostsFile=#{configuration.known_hosts}"] if configuration.known_hosts
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

        # 从指定 known_hosts 文件中删除当前设备的旧主机密钥。
        def replace_host_key
          host = configuration.host
          host = "[#{host}]:#{configuration.port}" if configuration.port && configuration.port != 22
          _output, status = Open3.capture2e("ssh-keygen", "-f", configuration.known_hosts, "-R", host)
          raise IOError, "removing device host key failed" unless status.success?
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
