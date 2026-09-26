# frozen_string_literal: true

# 可观察的字节传输替身；不会创建 Expect，也不会打开真实套接字。
class ConnectorFake
  attr_accessor :log_output, :on_write, :on_close, :on_interact
  attr_reader :writes, :reads, :opens, :closes, :events

  def initialize(*events)
    @events = events
    @writes = []
    @reads = []
    @opens = @closes = 0
    @closed = true
  end

  def protocol = :fake

  def closed? = @closed

  def open
    @closed = false
    @opens += 1
    self
  end

  def read(patterns, timeout:)
    @reads << timeout
    event = @events.shift || :timeout
    event = event.call(patterns, timeout) if event.respond_to?(:call)
    return event if event.is_a?(Net::Connector::Event)
    return Net::Connector::Event.new(error: event) unless event.is_a?(String)

    log_output&.write(event)
    patterns.each_with_index do |pattern, index|
      match = pattern.match(event.b)
      next unless match

      rest = event.b.byteslice(match.end(0)..)
      @events.unshift(rest) unless rest.empty?
      return Net::Connector::Event.new(index: index, before: event.b.byteslice(0, match.begin(0)),
                                       match: match[0])
    end
    Net::Connector::Event.new(index: patterns.size, match: event.b)
  end

  def write(bytes, timeout:)
    raise IOError, "closed fake transport" if closed?

    @writes << bytes.dup
    on_write&.call(bytes, timeout)
    bytes.bytesize
  end

  def close
    return if closed?

    @closed = true
    @closes += 1
    on_close&.call
  end

  def interact(**options) = on_interact ? on_interact.call(options) : :input
end
