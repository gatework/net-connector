# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "rbconfig"
require "fileutils"
require "time"

module MemoryBenchmark
  MIB = 1024 * 1024
  DEFAULTS = { "transport" => "fake", "phase" => "retain", "response_bytes" => MIB,
               "commands" => 1, "concurrency" => 1, "output_calls" => 5, "logging" => "default" }.freeze

  def self.validate!(spec)
    { "transport" => %w[fake pty], "phase" => %w[retain response render clean parse collect], "logging" => %w[default debug] }.each do |key, values|
      raise ArgumentError, "invalid #{key}" unless values.include?(spec.fetch(key))
    end
    { "response_bytes" => (1024..(32 * MIB)), "commands" => (1..100), "concurrency" => (1..16), "output_calls" => (1..20) }.each do |key, range|
      value = spec.fetch(key)
      raise ArgumentError, "invalid #{key}" unless value.is_a?(Integer) && range.cover?(value)
    end
    unless spec.fetch("phase") == "retain" || (spec.fetch("commands") == 1 && spec.fetch("concurrency") == 1)
      raise ArgumentError, "component samples use one response and one worker"
    end
    bytes = spec.fetch("response_bytes") * spec.fetch("commands") * spec.fetch("concurrency")
    raise ArgumentError, "sample exceeds 128 MiB retained-output envelope" if bytes > 128 * MIB
    if spec["script_budget_bytes"] && (!spec["script_budget_bytes"].is_a?(Integer) || !spec["script_budget_bytes"].positive?)
      raise ArgumentError, "invalid script_budget_bytes"
    end
    spec
  end

  def self.samples(suite)
    retain = [[1, 1, 1], [8, 1, 1], [32, 1, 1], [1, 10, 1], [1, 100, 1], [1, 1, 4], [1, 1, 16]].map do |mib, commands, concurrency|
      DEFAULTS.merge("response_bytes" => mib * MIB, "commands" => commands, "concurrency" => concurrency)
    end
    pty = [[1, 1, 1], [8, 1, 1], [1, 10, 1], [1, 1, 4]].map do |mib, commands, concurrency|
      DEFAULTS.merge("transport" => "pty", "response_bytes" => mib * MIB, "commands" => commands, "concurrency" => concurrency)
    end
    components = %w[response render clean parse collect].product([1, 8]).map do |phase, mib|
      DEFAULTS.merge("phase" => phase, "response_bytes" => mib * MIB)
    end
    cases = retain + pty + components + [DEFAULTS.merge("logging" => "debug"), DEFAULTS.merge("phase" => "collect", "transport" => "pty")]
    return cases if suite == "baseline"

    cases.values_at(0, 7, 11, 13, 15, 17, 19, 21, 22).map { |spec| spec.merge("response_bytes" => 16 * 1024, "output_calls" => 2) }
  end

  def self.machine
    data = { ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, cpus: nil, memory_bytes: nil, cpu: nil }
    if RUBY_PLATFORM.include?("darwin")
      %w[hw.logicalcpu hw.memsize machdep.cpu.brand_string].zip(%i[cpus memory_bytes cpu]).each do |key, field|
        output, _error, status = Open3.capture3("sysctl", "-n", key)
        data[field] = field == :cpu ? output.strip : output.to_i if status.success?
      end
    elsif File.file?("/proc/meminfo")
      data[:memory_bytes] = File.read("/proc/meminfo")[/^MemTotal:\s+(\d+)/, 1].to_i * 1024
      data[:cpus] = File.read("/proc/cpuinfo").scan(/^processor\s*:/).size
      data[:cpu] = File.read("/proc/cpuinfo")[/^model name\s*:\s*(.+)/, 1]
    end
    data
  end

  def self.run_case(spec, directory, index)
    validate!(spec)
    option = RUBY_PLATFORM.include?("darwin") ? "-l" : "-v"
    output, errors, status = Open3.capture3({ "LC_ALL" => "C" }, "/usr/bin/time", option, RbConfig.ruby, __FILE__, "--worker", JSON.generate(spec))
    raw = File.join(directory, format("%02d-time.txt", index))
    File.write(raw, errors)
    raise "benchmark worker failed; see #{raw}" unless status.success?

    maximum = if option == "-l"
                errors[/^\s*(\d+)\s+maximum resident set size/, 1]&.to_i
              else
                errors[/Maximum resident set size \(kbytes\):\s*(\d+)/, 1]&.to_i&.*(1024)
              end
    raise "maximum RSS was not reported" unless maximum&.positive?

    JSON.parse(output).merge("sample" => spec, "peak_rss_bytes" => maximum, "time_log" => raw)
  end

  def self.main(arguments)
    if arguments.first == "--worker"
      require_relative "benchmarks/memory_workload"
      spec = validate!(JSON.parse(arguments.fetch(1)))
      puts JSON.generate(Workload.new(spec).run)
      return
    end
    suite = "smoke"
    $stdout.sync = true
    directory = "tmp/benchmarks/memory-#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}"
    custom = {}
    help = false
    parser = OptionParser.new do |options|
      options.banner = "Usage: bundle exec ruby script/benchmark_memory.rb [--suite smoke|baseline] [--directory PATH]"
      options.on("--suite NAME", %w[smoke baseline]) { |value| suite = value }
      options.on("--directory PATH") { |value| directory = value }
      options.on("--transport NAME", %w[fake pty]) { |value| custom["transport"] = value }
      options.on("--phase NAME", %w[retain response render clean parse collect]) { |value| custom["phase"] = value }
      %w[response_bytes commands concurrency output_calls script_budget_bytes].each do |key|
        options.on("--#{key.tr("_", "-")} N", Integer) { |value| custom[key] = value }
      end
      options.on("--logging NAME", %w[default debug]) { |value| custom["logging"] = value }
      options.on("-h", "--help") { puts options; help = true }
    end
    parser.parse!(arguments)
    return if help
    raise ArgumentError, "unexpected benchmark arguments" unless arguments.empty?

    cases = custom.empty? ? samples(suite) : [DEFAULTS.merge(custom)]
    cases.each { |spec| validate!(spec) }
    raise ArgumentError, "benchmark output directory already exists" if File.exist?(directory)

    FileUtils.mkdir_p(directory)
    report = { schema_version: 1, started_at: Time.now.utc.iso8601, machine: machine, samples: [],
               limits: ["Synthetic data and local PTY only; no network", "Samples run serially in separate processes with normal GC",
                        "Peak RSS is the external time command high-water measurement; it is not summed device or worker RSS",
                        "RSS endpoints are measured with ps outside each timed allocation interval",
                        "Fixture construction and connection precede phase timing but are included in whole-process peak RSS",
                        "Default logging matches Configuration defaults; debug case uses Logger and a counting sink",
                        "Full outputs and normal protocol validation are retained; sample output envelope is limited to 128 MiB"] }
    path = File.join(directory, "results.json")
    cases.each_with_index do |spec, index|
      result = run_case(spec, directory, index)
      report[:samples] << result
      File.write(path, JSON.pretty_generate(report) + "\n")
      puts "#{index + 1}/#{cases.size} #{spec.fetch("transport")} #{spec.fetch("phase")} bytes=#{spec.fetch("response_bytes")} commands=#{spec.fetch("commands")} workers=#{spec.fetch("concurrency")} peak_rss=#{result.fetch("peak_rss_bytes")}"
    end
    report[:finished_at] = Time.now.utc.iso8601
    File.write(path, JSON.pretty_generate(report) + "\n")
    puts "Results: #{path}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    MemoryBenchmark.main(ARGV)
  rescue StandardError => error
    warn "memory benchmark: #{error.message}"
    exit 1
  end
end
