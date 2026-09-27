# frozen_string_literal: true

# 纯合成 IOS 风格文本；基准父进程和本地 PTY 子进程共用生成规则。
module MemoryFixture
  PROMPT = "router#"
  BLOCK = "interface Ethernet1/1\n description #{"x" * 944}\n!\n".b.freeze

  def self.payload(bytes)
    blocks, tail = bytes.divmod(BLOCK.bytesize)
    text = BLOCK * blocks
    text << ("!" * (tail - 1)) << "\n" if tail.positive?
    text.freeze
  end
end

if $PROGRAM_NAME == __FILE__
  STDOUT.sync = true
  payload = MemoryFixture.payload(Integer(ARGV.fetch(0), 10))
  STDOUT.write(MemoryFixture::PROMPT)
  while (command = STDIN.gets)
    case command.strip
    when /\Ashow (?:fixture \d+|running-config)\z/
      STDOUT.write(payload)
    when "terminal length 0"
      # 模拟分页设置的空响应；仍由正常命令流程执行并保留完成步骤。
    else
      abort "unsupported benchmark command"
    end
    STDOUT.write(MemoryFixture::PROMPT)
  end
end
