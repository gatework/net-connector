# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"

class NetdiscoResourcesTest < Minitest::Test
  def test_low_soft_limit_is_raised_before_opening_archive_pipes_device_ptys_and_logs
    result = isolated(<<~'RUBY')
      require "pty"
      require "tmpdir"
      require "net/connector/netdisco/resources"
      hard = Process.getrlimit(:NOFILE).last
      Process.setrlimit(:NOFILE, 256, hard)
      Net::Connector::Netdisco::Resources.prepare!(parallel: 50)
      owned = []
      begin
        Dir.mktmpdir do |directory|
          50.times do |index|
            3.times { owned.concat(IO.pipe) }
            owned.concat(PTY.open)
            owned << File.open(File.join(directory, index.to_s), "w")
          end
        end
        puts JSON.generate(opened: owned.size, soft: Process.getrlimit(:NOFILE).first,
                           hard_unchanged: Process.getrlimit(:NOFILE).last == hard)
      ensure
        owned.each(&:close)
      end
    RUBY
    assert_equal 450, result.fetch("opened")
    assert_operator result.fetch("soft"), :>=, 928
    assert result.fetch("hard_unchanged")
  end

  def test_insufficient_hard_limit_stops_before_archives_and_device_credentials
    result = isolated(<<~'RUBY')
      require "tmpdir"
      require "net/connector/netdisco"
      Process.setrlimit(:NOFILE, 256, 256)
      n = Net::Connector::Netdisco
      rows = (1..50).map { |i| { "ip" => "192.0.2.#{i}", "vendor" => "H3C" } }
      factory = ->(*) { abort "device connection must not start" }
      fleet = n::Fleet.new(inventory: Struct.new(:devices).new(rows), credentials: factory, report_store: nil)
      n::Tftp::Archive.define_singleton_method(:new) { |**| abort "archive must not start" }
      Dir.mktmpdir do |directory|
        begin
          fleet.tftp_backup_all(server: "192.0.2.10", parallel: 50, limit_per_vendor: nil, report_directory: directory, preserve_history: true)
          abort "insufficient resources permitted execution"
        rescue ArgumentError => error
          puts JSON.generate(message: error.message, cause_nil: error.cause.nil?)
        end
      end
    RUBY
    assert_includes result.fetch("message"), "文件描述符额度不足"
    assert_includes result.fetch("message"), "未连接设备"
    assert result.fetch("cause_nil")
  end

  private

  def isolated(script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rjson", "-e", script)
    assert status.success?, stderr
    JSON.parse(stdout)
  end
end
