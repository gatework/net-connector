# frozen_string_literal: true

require "stringio"
require_relative "errors"

module Net
  module Connector
    # 把终端编辑控制符渲染成可读、兼容 UTF-8 和二进制的逐行日志。
    class TerminalRenderer
      # 将字节流完整渲染为字符串，供测试和一次性转换使用。
      def self.render(input, strict_utf8: false)
        output = StringIO.new("".b)
        renderer = new(output, strict_utf8: strict_utf8)
        renderer.write(input)
        renderer.finish
        output.string
      end

      # 初始化当前行、光标和转义序列状态。
      def initialize(target, max_line_bytes: 32 * 1024 * 1024, strict_utf8: false)
        raise ArgumentError, "target must respond to write" unless target.respond_to?(:write)
        unless max_line_bytes.is_a?(Integer) && max_line_bytes.positive?
          raise ArgumentError, "max_line_bytes must be positive"
        end
        raise ArgumentError, "strict_utf8 must be true or false" unless [true, false].include?(strict_utf8)

        @target = target
        @line = "".b
        @cursor = 0
        @escape_state = nil
        @csi_parameters = "".b
        @max_line_bytes = max_line_bytes
        @strict_utf8 = strict_utf8
      end

      # 逐字节消费终端输出，并返回输入字节数。
      def write(input)
        bytes = input.to_s.b
        bytes.each_byte { |byte| consume(byte) }
        bytes.bytesize
      end

      # 刷新底层日志目标。
      def flush
        @target.flush if @target.respond_to?(:flush)
      end

      # 写出尚未换行的尾行并刷新目标。
      def finish
        emit_line(newline: false) unless @line.empty?
        flush
      end

      private

      # 处理普通控制字符、换行、回车和转义序列起始符。
      def consume(byte)
        return consume_escape(byte) if @escape_state

        case byte
        when 7 then nil
        when 8 then @cursor = [@cursor - 1, 0].max
        when 10 then emit_line(newline: true)
        when 13 then @cursor = 0
        when 27 then @escape_state = :escape
        else write_byte(byte) if byte == 9 || byte >= 32
        end
      end

      # 根据转义序列阶段继续解析终端控制字节。
      def consume_escape(byte)
        case @escape_state
        when :escape
          start_escape_sequence(byte)
        when :csi
          finish_csi(byte)
        when :osc
          @escape_state = nil if byte == 7
          @escape_state = :osc_escape if byte == 27
        when :osc_escape
          @escape_state = (byte == 92) ? nil : :osc
        end
      end

      # 识别 CSI 或 OSC 序列，并忽略未知的单字节序列。
      def start_escape_sequence(byte)
        case byte
        when 91
          @csi_parameters.clear
          @escape_state = :csi
        when 93 then @escape_state = :osc
        else
          @escape_state = nil
        end
      end

      # 收集 CSI 参数并在终止字节到达时执行光标操作。
      def finish_csi(byte)
        if byte.between?(0x40, 0x7e)
          apply_csi(byte)
          @escape_state = nil
        elsif byte.between?(0x20, 0x3f)
          raise OutputLimitExceeded, "terminal escape sequence is too long" if @csi_parameters.bytesize >= 64

          @csi_parameters << byte
        else
          @escape_state = nil
        end
      end

      # 应用有限范围内的光标移动和整行擦除控制。
      def apply_csi(command)
        count = Integer(@csi_parameters[/\d+/, 0] || "1", 10)
        case command
        when 67 then @cursor += count
        when 68 then @cursor = [@cursor - count, 0].max
        when 71 then @cursor = [count - 1, 0].max
        when 75 then erase_line(Integer(@csi_parameters[/\d+/, 0] || "0", 10))
        end
      end

      # 按终端擦除模式修改当前行缓冲区。
      def erase_line(mode)
        case mode
        when 0 then @line = @line.byteslice(0, @cursor)
        when 1
          @line = (" " * [@cursor + 1, @line.bytesize].min) + @line.byteslice((@cursor + 1)..).to_s
        when 2
          @line.clear
          @cursor = 0
        end
      end

      # 在光标位置写入字节，并限制单行缓冲大小。
      def write_byte(byte)
        raise OutputLimitExceeded, "terminal line exceeded max_line_bytes" if @cursor >= @max_line_bytes

        @line << (" " * (@cursor - @line.bytesize)) if @cursor > @line.bytesize
        (@cursor < @line.bytesize) ? @line.setbyte(@cursor, byte) : @line << byte
        @cursor += 1
      end

      # 删除行尾空白，写出当前行并重置光标。
      def emit_line(newline:)
        @target.write(utf8_safe(@line.sub(/[ \t]+\z/n, "")))
        @target.write("\n") if newline
        @line.clear
        @cursor = 0
      end

      # 日志把非法字节转义；解析必须拒绝终端编辑产生的损坏字节，不能制造可写业务证据。
      def utf8_safe(line)
        text = line.dup.force_encoding(Encoding::UTF_8)
        return text.b if text.valid_encoding?
        raise Encoding::InvalidByteSequenceError, "terminal editing produced invalid UTF-8" if @strict_utf8

        text.scrub { |invalid| invalid.bytes.map { |byte| format("\\x%02X", byte) }.join }.b
      end
    end
  end
end
