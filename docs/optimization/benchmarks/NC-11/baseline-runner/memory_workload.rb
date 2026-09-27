# frozen_string_literal: true

require "json"
require "logger"
require "open3"
require "rbconfig"
require_relative "../../lib/net/connector"
require_relative "../../test/support/fake_transport"
require_relative "memory_fixture"

module MemoryBenchmark
  # 保留 Logger 的过滤和格式化成本，但不把合成配置积存在另一个 StringIO 中。
  class CountingLog
    attr_reader :bytes

    def initialize = @bytes = 0

    def write(text) = @bytes += text.bytesize

    def close; end
  end

  class LocalTransport < Net::Connector::Transports::Pty
    attr_reader :channel, :last_channel, :writes

    def initialize(configuration, bytes)
      super(configuration)
      @bytes = bytes
      @writes = 0
    end

    def argv = [RbConfig.ruby, "--disable-gems", File.expand_path("memory_fixture.rb", __dir__), @bytes.to_s]

    def write(bytes, **options)
      @writes += 1
      super
    end

    def close
      @last_channel = @channel if @channel
      super
    end
  end

  class Workload
    def initialize(spec)
      @spec = spec
      @payload = MemoryFixture.payload(spec.fetch("response_bytes"))
      @response = (@payload + MemoryFixture::PROMPT).freeze
      @metrics = []
      @devices = []
      @transports = []
      @logs = []
    end

    def run
      @spec.fetch("concurrency").times { setup_device }
      GC.start
      results = measure(@spec.fetch("phase")) { concurrent { |device| perform(device) } }
      retained = results.sum { |result| result.is_a?(Net::Connector::Result) ? result.steps.sum { |step| step.output.bytesize } : 0 }
      if results.all?(Net::Connector::Result)
        measure("result_output_once") { results.each { |result| verify_output(result, retained / results.size) } }
        measure("result_output_repeated") do
          @spec.fetch("output_calls").times { results.each { |result| verify_output(result, retained / results.size) } }
        end
      end
      { metrics: @metrics, retained_step_bytes: retained, result_count: results.size,
        completed_steps: results.sum { |result| result.is_a?(Net::Connector::Result) ? result.steps.size : 0 },
        commands_sent: @transports.sum { |transport| transport.writes.is_a?(Array) ? transport.writes.size : transport.writes },
        logged_bytes: @logs.sum(&:bytes), error_codes: results.filter_map { |result| result.error&.code if result.is_a?(Net::Connector::Result) } }
    ensure
      @devices.each(&:close)
      @transports.grep(LocalTransport).each do |transport|
        channel = transport.last_channel
        raise "benchmark PTY was not closed" if channel && (!channel.closed? || channel.alive?)
        next unless channel&.pid

        begin
          Process.waitpid(channel.pid, Process::WNOHANG)
          raise "benchmark PTY was not reaped"
        rescue Errno::ECHILD
          # hard_close 已回收所属子进程。
        end
      end
    end

    private

    def setup_device
      options = { host: "192.0.2.1", username: "benchmark", command_timeout: 60,
                  max_output_bytes: @response.bytesize + 65_536 }
      options[:max_script_output_bytes] = @spec["script_budget_bytes"] if @spec["script_budget_bytes"]
      if @spec.fetch("logging") == "debug"
        target = CountingLog.new
        @logs << target
        options.merge!(logger: Logger.new(target), log_level: :debug)
      end
      configuration = Net::Connector::Configuration.new(**options)
      transport = @spec.fetch("transport") == "pty" ? LocalTransport.new(configuration, @payload.bytesize) : fake_transport
      device = Net::Connector.build(:cisco_ios, configuration: configuration, transport: transport)
      @transports << transport
      @devices << device
      device.connect
    end

    # 每次仅产生一个分片，不预先分配所有命令的响应；协议匹配复用已有 ConnectorFake。
    def fake_transport
      ConnectorFake.new(MemoryFixture::PROMPT).tap do |transport|
        transport.on_write = lambda do |command, _timeout|
          response = command.strip == "terminal length 0" ? MemoryFixture::PROMPT : @response
          cursor = 0
          next_chunk = lambda do |*_|
            remaining = response.bytesize - cursor
            length = remaining <= 16_384 + MemoryFixture::PROMPT.bytesize ? remaining : 16_384
            chunk = response.byteslice(cursor, length)
            cursor += chunk.bytesize
            transport.events << next_chunk if cursor < response.bytesize
            chunk
          end
          transport.events << next_chunk
        end
      end
    end

    def concurrent
      return [yield(@devices.first)] if @devices.size == 1

      ready = Queue.new
      start = Queue.new
      workers = []
      @devices.each do |device|
        workers << Thread.new { ready << true; start.pop; yield device }
      end
      workers.size.times { ready.pop }
      workers.size.times { start << true }
      workers.map(&:value)
    ensure
      workers&.each { |worker| worker.kill if worker.alive? }
      workers&.each(&:join)
    end

    def perform(device)
      case @spec.fetch("phase")
      when "retain"
        result = device.execute_script(Array.new(@spec.fetch("commands")) { |index| "show fixture #{index}" })
        verify_result(result, @spec.fetch("commands"))
      when "collect"
        result = device.running_config
        verify_result(result, device.config_commands.size)
        raise "configuration collection lost fixture data" unless result.config.include?(MemoryFixture::BLOCK.strip)

        result
      when "response"
        session = device.instance_variable_get(:@session)
        response = session.perform(:script) { session.exchange(Net::Connector::Command.new("show fixture 0"), timeout: 60) }
        raise "response buffering changed fixture bytes" unless response.raw == @response && response.output == @response

        response
      when "render", "clean"
        text = @spec.fetch("phase") == "render" ? Net::Connector::TerminalRenderer.render(@response) : device.clean_config(@response)
        raise "terminal processing changed fixture bytes" unless text == @response

        text
      when "parse"
        rows = Net::Connector::Operations::ParseOutput.new.call(@payload, template: "cisco_ios_running_config_interfaces.textfsm")
        raise "parser lost fixture records" unless rows.size == @payload.bytesize / MemoryFixture::BLOCK.bytesize

        rows
      end
    end

    def verify_result(result, count)
      if @spec["script_budget_bytes"]
        raise "script budget did not stop the fixture" unless result.error&.code == :script_output_limit_exceeded
      else
        raise "fixture execution failed" unless result.success? && result.steps.size == count
      end
      raise "step outputs were discarded" unless result.steps.all? { |step| step.output.end_with?(MemoryFixture::PROMPT) }

      result
    end

    def verify_output(result, bytes)
      raise "Result#output lost bytes" unless result.output.bytesize == bytes
    end

    def measure(name)
      rss_before = rss
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      count = GC.stat(:total_allocated_objects) - allocated
      @metrics << { phase: name, elapsed_seconds: elapsed, allocated_objects: count, rss_before_bytes: rss_before, rss_after_bytes: rss }
      value
    end

    def rss
      output, errors, status = Open3.capture3("ps", "-o", "rss=", "-p", Process.pid.to_s)
      raise "unable to measure RSS: #{errors}" unless status.success?

      Integer(output.strip, 10) * 1024
    end
  end
end
