# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require_relative "../lib/net/connector"

class ConnectorTransportTest < Minitest::Test
  Connector = Net::Connector

  # 对端仅是本地 Ruby 子进程；真实 PTY 验证分片、写入和进程回收，不连接网络。
  class LocalTransport < Connector::Transports::Pty
    attr_reader :channel

    def initialize(configuration, script, **options)
      super(configuration, **options)
      @script = script
    end

    def argv = [RbConfig.ruby, "--disable-gems", "-e", @script]
  end

  def test_fragmented_pager_preserves_output_and_reaps_the_child
    device, transport = local_device(<<~'RUBY')
      $stdout.sync = true
      $stdout.write("router#")
      abort unless $stdin.gets == "show\n"
      $stdout.write("first\n--Mo")
      sleep 0.02
      $stdout.write("re--")
      abort unless $stdin.read(1) == " "
      $stdout.write("\nlast\nrouter#")
      $stdin.read
    RUBY

    result = device.execute("show")
    assert result.success?, result.error&.message
    assert_equal "first\n\nlast\nrouter#", result.output
    channel = transport.channel
    pid = channel.pid
    device.close
    assert channel.closed?
    refute channel.alive?
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  ensure
    device&.close
  end

  def test_unmatched_output_limit_stops_the_script_and_closes_the_real_transport
    device, transport = local_device(<<~'RUBY', max_output_bytes: 1024)
      $stdout.sync = true
      $stdout.write("router#")
      abort unless $stdin.gets == "show\n"
      $stdout.write("x" * 16384)
      $stdin.read
    RUBY

    result = device.execute_script(["show", "never"])
    assert_instance_of Connector::OutputLimitExceeded, result.error
    assert_equal "show", result.error.command
    assert_operator result.error.output.bytesize, :<=, 4096
    assert_empty result.steps
    assert transport.closed?
    refute device.connected?
  ensure
    device&.close
  end

  def test_streaming_progress_does_not_restart_the_command_deadline
    device, transport = local_device(<<~'RUBY')
      $stdout.sync = true
      $stdout.write("router#")
      abort unless $stdin.gets == "show\n"
      loop do
        $stdout.write("progress\n")
        sleep 0.01
      end
    RUBY
    device.connect
    channel = transport.channel
    started = Expect.monotonic

    result = device.execute("show", timeout: 0.1)

    assert_instance_of Connector::CommandTimeout, result.error
    assert_operator Expect.monotonic - started, :<, 2
    assert_includes result.error.output, "progress"
    assert channel.closed?
    refute channel.alive?
  ensure
    device&.close
  end

  def test_zero_width_prompt_cannot_complete_commands_from_stale_buffer
    device, transport = local_device(<<~'RUBY')
      $stdout.sync = true
      $stdout.write("router#")
      abort unless $stdin.gets == "show first\n"
      $stdout.write("first\nrouter#")
      $stdin.gets
      sleep 5
    RUBY
    command = Connector::Command.new("show first", prompt: /(?=router#)/)

    result = device.execute_script([command, "show second"])

    assert_instance_of Connector::PromptError, result.error
    assert_equal "show first", result.error.command
    assert_equal :command, result.error.phase
    assert_equal "first\n", result.error.output
    assert_empty result.steps
    assert transport.closed?
  ensure
    device&.close
  end

  def test_streaming_window_retains_the_entire_command_output
    device, = local_device(<<~'RUBY')
      $stdout.sync = true
      print "router#"
      abort unless $stdin.gets == "show\n"
      print "x" * 100_000
      print "\nrouter#"
      $stdin.read
    RUBY

    result = device.execute("show")

    assert result.success?, result.error&.message
    assert_equal ("x" * 100_000) + "\nrouter#", result.output
  ensure
    device&.close
  end

  def test_eof_preserves_completed_steps_and_reaps_the_child
    device, transport = local_device(<<~'RUBY')
      $stdout.sync = true
      print "router#"
      abort unless $stdin.gets == "first\n"
      print "done\nrouter#"
      abort unless $stdin.gets == "second\n"
      print "unfinished response"
    RUBY
    device.connect
    channel = transport.channel
    pid = channel.pid

    result = device.execute_script(%w[first second never])

    assert_instance_of Connector::ConnectionClosed, result.error
    assert_equal ["first"], (result.steps.map { |step| step.command.text })
    assert_equal "second", result.error.command
    assert_includes result.error.output, "unfinished response"
    assert channel.closed?
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  ensure
    device&.close
  end

  def test_zero_width_login_prompt_cannot_authenticate_a_session
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test", login_timeout: 2)
    transport = LocalTransport.new(configuration, '$stdout.sync = true; print "router#"; $stdin.read')
    connector = Class.new(Connector.vendor_class(:cisco_ios)) do
      profile { prompts { login(/(?=router#)/) } }
    end
    device = connector.new(configuration: configuration, transport: transport)

    error = assert_raises(Connector::PromptError) { device.connect }

    assert_equal :login, error.phase
    assert transport.closed?
    refute device.connected?
  ensure
    device&.close
  end

  def test_profile_terminal_dimensions_reach_the_child_as_rows_and_columns
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test", login_timeout: 2)
    profile = Connector::Profile.define { terminal_size 100, 40 }
    transport = LocalTransport.new(configuration, <<~'RUBY', terminal_size: profile.terminal_size)
      require "io/console"
      $stdout.sync = true
      $stdout.write("router#")
      abort unless $stdin.gets == "show size\n"
      $stdout.write("size=#{$stdout.winsize.join(',')}\nrouter#")
      $stdin.read
    RUBY
    device = Connector.build(:cisco_ios, configuration: configuration, transport: transport)

    result = device.execute("show size")

    assert result.success?, result.error&.message
    assert_equal "size=40,100\nrouter#", result.output
  ensure
    device&.close
  end

  private

  def local_device(script, **options)
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test",
                                                 login_timeout: 2, command_timeout: 2, **options)
    transport = LocalTransport.new(configuration, script)
    [Connector.build(:cisco_ios, configuration: configuration, transport: transport), transport]
  end
end
