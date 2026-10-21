# frozen_string_literal: true

require "json"
require "optparse"

# 比较相同输入下的诊断扫描；可指向独立源码副本，不覆盖当前工作区。
library = File.expand_path("../lib", __dir__)
smoke = false
OptionParser.new do |options|
  options.on("--library PATH") { |path| library = File.expand_path(path) }
  options.on("--smoke") { smoke = true }
end.parse!
$LOAD_PATH.unshift(library)
require "net/connector"

dialogue = Net::Connector::Dialogue.new(login_prompt: />/, command_prompt: />/, password_prompt: /password:/,
                                       username_prompt: /username:/, enable_prompt: /#/,
                                       authentication_errors: [], command_errors: [/Error:/],
                                       login_interactions: [], command_interactions: [])
plain = "interface GigabitEthernet1/0/1\n description ordinary output\n" * (smoke ? 10 : 32_768)
cases = {
  plain_lf: [plain, nil],
  plain_crlf: [plain.gsub("\n", "\r\n"), nil],
  failure: ["#{plain}Error: invalid command\nrouter>", "Error: invalid command"],
  colored_redraw: ["#{plain}\e[31mError:\e[0m invalid command\rcleared\e[K\nrouter>", "Error: invalid command"]
}
puts JSON.generate(ruby: RUBY_DESCRIPTION, source: Net::Connector::Dialogue.instance_method(:diagnostic).source_location)
cases.each do |name, (input, expected)|
  input.freeze
  raise "Incorrect warmup: #{name}" unless dialogue.diagnostic(input) == expected

  samples = Array.new(smoke ? 1 : 5) do
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = nil
    (smoke ? 1 : 10).times { result = dialogue.diagnostic(input) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    objects = GC.stat(:total_allocated_objects) - allocated
    raise "Incorrect result: #{name}" unless result == expected

    { milliseconds: (elapsed * 1000).round(3), allocated_objects: objects }
  end
  puts JSON.generate(name: name, bytes: input.bytesize, iterations: smoke ? 1 : 10, samples: samples)
end
