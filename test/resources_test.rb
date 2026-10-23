# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"
require_relative "../lib/net/connector/resources"

class ResourcesTest < Minitest::Test
  def test_invalid_parallel_is_a_parameter_error_without_touching_process_limits
    [nil, "2", 0.0, -1, 501].each do |parallel|
      Process.stub(:getrlimit, ->(*) { flunk "invalid input must not inspect process limits" }) do
        error = assert_raises(ArgumentError) { Net::Connector::Resources.prepare!(parallel: parallel) }
        assert_includes error.message, "parallel"
        refute_includes error.message, "Insufficient local file descriptor limit"
      end
    end
  end

  def test_empty_batch_does_not_change_process_limits
    Process.stub(:getrlimit, ->(*) { flunk "empty batch must not inspect process limits" }) do
      assert_nil Net::Connector::Resources.prepare!(parallel: 0)
    end
  end

  def test_low_soft_limit_is_raised_before_opening_archive_pipes_device_ptys_and_logs
    result = isolated(<<~'RUBY')
      require "pty"
      require "tmpdir"
      require "net/connector/resources"
      hard = Process.getrlimit(:NOFILE).last
      Process.setrlimit(:NOFILE, 256, hard)
      Net::Connector::Resources.prepare!(parallel: 50)
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
    assert_includes result.fetch("message"), "Insufficient local file descriptor limit"
    assert_includes result.fetch("message"), "without connecting to devices"
    assert result.fetch("cause_nil")
  end

  private

  def isolated(script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rjson", "-e", script)
    assert status.success?, stderr
    JSON.parse(stdout)
  end
end
