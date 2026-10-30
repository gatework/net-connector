# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "securerandom"
require "stringio"
require "tmpdir"
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

  def test_ssh_startup_keeps_original_failure_when_trust_cleanup_also_fails
    [IOError.new("startup failed"), Interrupt.new("startup interrupted")].each do |original|
      configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test", host_key_policy: :accept_new)
      closed = 0
      cleanup_fails = true
      trust = Object.new
      trust.define_singleton_method(:close) { closed += 1; raise IOError, "cleanup failed" if cleanup_fails }
      transport = Connector::Transports::Ssh.new(configuration, channel_factory: -> { raise original })
      Connector::KnownHosts.stub(:new, trust) do
        raised = assert_raises(original.class) { transport.open }
        assert_same original, raised
      end
      assert_operator closed, :>=, 1
      assert transport.closed?
      cleanup_fails = false
      attempts = closed
      transport.close
      assert_equal attempts + 1, closed
      transport.close
      assert_equal attempts + 1, closed
    end
  end

  def test_channel_factory_cancellation_closes_the_returned_channel
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    closed = 0
    channel = Object.new
    channel.define_singleton_method(:hard_close) { closed += 1 }
    channel.define_singleton_method(:alive?) { false }
    original = Interrupt.new("cancel during channel handoff")
    factory = lambda do
      Thread.current.raise(original)
      channel
    end
    transport = Connector::Transports::Pty.new(configuration, channel_factory: factory)

    assert_same original, assert_raises(Interrupt) { transport.open }
    assert_equal 1, closed
    assert transport.closed?
  end

  def test_channel_factory_failure_wins_over_a_pending_cancellation
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    original = IOError.new("channel factory failed")
    factory = lambda do
      Thread.current.raise(Interrupt.new("pending cancellation"))
      raise original
    end
    transport = Connector::Transports::Pty.new(configuration, channel_factory: factory)

    assert_same original, assert_raises(Exception) { transport.open }
    assert transport.closed?
  end

  def test_channel_close_finishes_before_delivering_async_cancellation
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    transport = Connector::Transports::Pty.new(configuration)
    closed = 0
    original = Interrupt.new("cancel during channel close")
    channel = Object.new
    channel.define_singleton_method(:hard_close) do
      Thread.current.raise(original)
      closed += 1
    end
    channel.define_singleton_method(:alive?) { false }
    transport.instance_variable_set(:@channel, channel)

    assert_same original, assert_raises(Interrupt) { transport.close }
    assert_equal 1, closed
    assert transport.closed?
    transport.close
    assert_equal 1, closed
  end

  def test_ssh_trust_factory_cancellation_closes_the_returned_snapshot
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test", host_key_policy: :accept_new)
    closed = 0
    trust = Object.new
    trust.define_singleton_method(:close) { closed += 1 }
    original = Interrupt.new("cancel during trust handoff")
    factory = lambda do |*_, **_|
      Thread.current.raise(original)
      trust
    end
    transport = Connector::Transports::Ssh.new(configuration)

    Connector::KnownHosts.stub(:new, factory) do
      assert_same original, assert_raises(Interrupt) { transport.open }
    end
    assert_equal 1, closed
    assert transport.closed?
  end

  def test_failed_pty_close_retains_the_child_for_an_explicit_retry
    with_cleanup_transport do |transport, channels|
      channel = channels.last
      pid = channel.pid
      failure = Errno::EINVAL.new("wait failed")
      channel.stub(:wait, ->(**) { raise failure }) do
        assert_same failure, assert_raises(Errno::EINVAL) { transport.close }
      end
      assert transport.closed?
      assert channel.alive?

      transport.close

      refute channel.alive?
      assert_nil channel.pid
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      channel.stub(:hard_close, -> { flunk "completed channel closed again" }) { transport.close }
    end
  end

  def test_reopening_cannot_replace_a_channel_whose_cleanup_is_pending
    with_cleanup_transport do |transport, channels|
      channel = channels.last
      pid = channel.pid
      failure = Errno::EINVAL.new("wait failed")
      channel.stub(:wait, ->(**) { raise failure }) do
        assert_same failure, assert_raises(Errno::EINVAL) { transport.close }
        assert_same failure, assert_raises(Errno::EINVAL) { transport.open }
        assert_equal 1, channels.size
        assert channel.alive?
      end

      transport.open

      refute channel.alive?
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      assert_equal 2, channels.size
      assert channels.last.expect("ready", timeout: 5).matched?
      refute transport.closed?
    end
  end

  def test_bounded_pty_close_keeps_ownership_when_the_child_has_not_exited
    with_cleanup_transport do |transport, channels|
      channel = channels.last
      pid = channel.pid
      channel.stub(:hard_close, nil) do
        failure = assert_raises(IOError) { transport.close }
        assert_equal "PTY child is still running after hard close", failure.message
      end
      assert transport.closed?
      assert channel.alive?

      transport.close

      refute channel.alive?
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    end
  end

  def test_nonlocal_close_exit_keeps_the_child_available_for_cleanup
    with_cleanup_transport do |transport, channels|
      channel = channels.last
      channel.stub(:hard_close, -> { throw :abandoned, :stopped }) do
        assert_equal :stopped, catch(:abandoned) { transport.close }
      end
      assert transport.closed?
      assert channel.alive?

      transport.close

      refute channel.alive?
    end
  end

  def test_close_returns_the_reaped_child_status
    with_cleanup_transport do |transport, channels|
      status = transport.close

      assert_instance_of Process::Status, status
      assert_same channels.last.process_status, status
    end
  end

  def test_forked_transport_copy_closes_without_claiming_the_parents_child
    with_cleanup_transport do |transport, channels|
      copy_pid = fork do
        transport.close
        exit! 0
      rescue IOError
        exit! 17
      end
      status = Process.waitpid2(copy_pid).last

      assert status.success?, "inherited channel cleanup must not require reaping the parent's child"
      assert channels.last.alive?
      refute transport.closed?
    end
  end

  def test_ssh_reopen_finishes_old_resources_before_creating_trust_and_keeps_new_logging
    script = 'trap("HUP", "IGNORE"); STDOUT.sync = true; puts "ready"; loop { sleep 1 }'
    transport_type = Class.new(Connector::Transports::Ssh) do
      define_method(:argv) { [RbConfig.ruby, "--disable-gems", "-e", script] }
    end
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "audit", host_key_policy: :accept_new)
    channels, snapshots, closed = [], [], []
    factory = -> { Expect::Session.new.tap { |channel| channels << channel } }
    trust_factory = lambda do |*, **|
      Object.new.tap do |snapshot|
        snapshot.define_singleton_method(:close) { closed << snapshot }
        snapshots << snapshot
      end
    end
    transport = transport_type.new(configuration, channel_factory: factory)
    Connector::KnownHosts.stub(:new, trust_factory) do
      transport.open
      assert channels.last.expect("ready", timeout: 5).matched?
      channel = channels.last
      channel.stub(:wait, ->(**) { raise Errno::EINVAL, "wait failed" }) do
        assert_raises(Errno::EINVAL) { transport.close }
        assert_raises(Errno::EINVAL) { transport.open }
        assert_equal 1, snapshots.size
      end

      output = StringIO.new
      transport.log_output = output
      transport.open

      refute channel.alive?
      assert channels.last.expect("ready", timeout: 5).matched?
      assert_includes output.string, "ready"
      assert_equal 2, snapshots.size
      assert_equal [snapshots.first], closed
      status = transport.close
      assert_same channels.last.process_status, status
      assert_equal snapshots, closed
    end
  ensure
    channels&.each { |channel| channel.hard_close(timeout: 0) }
    transport&.close
  end

  def test_ssh_trust_factory_failure_wins_over_a_pending_cancellation
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test", host_key_policy: :accept_new)
    original = IOError.new("trust factory failed")
    factory = lambda do |*_, **_|
      Thread.current.raise(Interrupt.new("pending cancellation"))
      raise original
    end
    transport = Connector::Transports::Ssh.new(configuration)

    Connector::KnownHosts.stub(:new, factory) do
      assert_same original, assert_raises(Exception) { transport.open }
    end
    assert transport.closed?
  end

  def test_blocking_channel_factory_remains_cancelable_and_cleans_its_partial_resource
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    entered, cleaned, blocker = Queue.new, Queue.new, Queue.new
    transport = Connector::Transports::Pty.new(configuration, channel_factory: lambda {
      entered << true
      begin
        blocker.pop
      ensure
        cleaned << true
      end
    })
    thread = Thread.new do
      transport.open
    rescue Interrupt => error
      error
    end
    entered.pop
    original = Interrupt.new("cancel blocked channel factory")
    thread.raise(original)

    assert_same original, thread.value
    assert cleaned.pop
    assert transport.closed?
  ensure
    thread&.kill
    thread&.join
  end

  def test_ssh_close_keeps_channel_failure_after_deferred_trust_cancellation
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    transport = Connector::Transports::Ssh.new(configuration)
    closed = []
    original = IOError.new("channel close failed")
    channel, trust = Object.new, Object.new
    channel.define_singleton_method(:hard_close) { closed << :channel; raise original }
    trust.define_singleton_method(:close) do
      Thread.current.raise(Interrupt.new("cancel trust cleanup"))
      closed << :trust
    end
    transport.instance_variable_set(:@channel, channel)
    transport.instance_variable_set(:@known_hosts, trust)

    assert_same original, assert_raises(IOError) { transport.close }
    assert_equal %i[channel trust], closed
  end

  def test_write_preserves_primary_failure_when_timeout_restoration_also_fails
    [IOError.new("write failed"), Interrupt.new("write interrupted")].each do |original|
      configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
      transport = Connector::Transports::Pty.new(configuration)
      channel = Object.new
      timeouts = []
      channel.define_singleton_method(:write_timeout) { 5 }
      channel.define_singleton_method(:write_timeout=) do |value|
        timeouts << value
        raise IOError, "restoration failed" if timeouts.size == 2
      end
      channel.define_singleton_method(:write) { |_bytes| raise original }
      transport.instance_variable_set(:@channel, channel)

      raised = assert_raises(original.class) { transport.write("show status\n", timeout: 2) }
      assert_same original, raised
      assert_equal [2, 5], timeouts
    end
  end

  def test_successful_write_reports_timeout_restoration_failure_without_replaying
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    transport = Connector::Transports::Pty.new(configuration)
    channel = Object.new
    timeouts, writes = [], []
    original = IOError.new("restoration failed")
    channel.define_singleton_method(:write_timeout) { 5 }
    channel.define_singleton_method(:write_timeout=) do |value|
      timeouts << value
      raise original if timeouts.size == 2
    end
    channel.define_singleton_method(:write) { |bytes| writes << bytes; bytes.bytesize }
    transport.instance_variable_set(:@channel, channel)

    assert_same original, assert_raises(IOError) { transport.write("show status\n", timeout: 2) }
    assert_equal [2, 5], timeouts
    assert_equal ["show status\n"], writes
  end

  def test_ssh_close_attempts_both_resources_and_keeps_the_first_failure
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    transport = Connector::Transports::Ssh.new(configuration)
    closed = []
    original = Interrupt.new("channel interrupted")
    channel, trust = Object.new, Object.new
    channel.define_singleton_method(:hard_close) { closed << :channel; raise original }
    trust.define_singleton_method(:close) { closed << :trust; raise IOError, "trust cleanup failed" }
    transport.instance_variable_set(:@channel, channel)
    transport.instance_variable_set(:@known_hosts, trust)
    raised = assert_raises(Interrupt) { transport.close }
    assert_same original, raised
    assert_equal %i[channel trust], closed
    assert_same original, assert_raises(Interrupt) { transport.close }
    assert_equal %i[channel trust channel trust], closed
  end

  def test_ssh_close_retries_failed_trust_cleanup_and_releases_it_only_after_success
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test")
    transport = Connector::Transports::Ssh.new(configuration)
    closed = 0
    trust = Object.new
    original = IOError.new("trust cleanup failed")
    trust.define_singleton_method(:close) { closed += 1; raise original if closed == 1 }
    transport.instance_variable_set(:@known_hosts, trust)
    raised = assert_raises(IOError) { transport.close }
    assert_same original, raised
    transport.close
    assert_equal 2, closed
    transport.close
    assert_equal 2, closed
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

    result = device.execute_command("show")
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

  # 容量检查不能为每个正常分片取得正文快照；Unicode 也按字节计量。
  def test_buffer_size_capability_avoids_snapshots_until_the_output_limit_is_exceeded
    with_buffer_channel do |buffer, transcript, snapshots, log|
      buffer.replace("中x")
      assert_equal 4, transcript.write("中x")
      assert_empty snapshots
      assert_equal "中x", log.string

      buffer << "y"
      error = assert_raises(Connector::OutputLimitExceeded) { transcript.write("y") }
      assert_equal "中xy".bytes, error.output.bytes
      assert_equal "中x", log.string
      buffer.clear
      assert_equal "中xy".bytes, error.output.bytes
    end
  end

  def test_disabled_logging_still_enforces_the_output_limit
    with_buffer_channel(logging: false) do |buffer, transcript, _snapshots, _log|
      buffer.replace("abcd")
      assert_equal 4, transcript.write("abcd")
      buffer << "e"
      error = assert_raises(Connector::OutputLimitExceeded) { transcript.write("e") }
      assert_equal "abcde", error.output
    end
  end

  # 注入信道同样遵守当前 Session 契约，不会因为碰巧存在旧方法而走另一条路径。
  def test_reads_use_the_current_expect_result_contract
    channel = Object.new
    channel.define_singleton_method(:expect_result) { |*, **| raise "legacy reader must not be called" }
    channel.define_singleton_method(:expect) do |*patterns, timeout:|
      raise "incorrect read arguments" unless patterns == [/router#/, LocalTransport::STREAM] && timeout == 2

      Expect::Result.new(status: :matched, match_number: 1, before: "output", match: "router#")
    end
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "audit")
    transport = LocalTransport.new(configuration, "")
    transport.instance_variable_set(:@channel, channel)
    event = transport.read([/router#/], timeout: 2)
    assert_equal 0, event.index
    assert_equal "output", event.before
    assert_equal "router#", event.match
  end

  def test_pty_waiting_events_and_original_errors_are_adapted_explicitly
    failure = IOError.new("read failed")
    { eof: :eof, timeout: :timeout, error: failure }.each do |status, expected|
      result = Expect::Result.new(status:, error: status == :error ? failure : nil, before: "tail")
      channel = Object.new
      channel.define_singleton_method(:expect) { |*, **| result }
      configuration = Connector::Configuration.new(host: "192.0.2.1", username: "audit")
      transport = LocalTransport.new(configuration, "")
      transport.instance_variable_set(:@channel, channel)

      event = transport.read([/router#/], timeout: 2)
      assert_same expected, event.error
      assert_nil event.index
      assert_equal "tail", event.before
      assert_equal "", event.match
    end
  end

  def test_cumulative_output_limit_keeps_finished_steps_and_reaps_the_local_pty
    device, transport = local_device(<<~'RUBY', max_script_output_bytes: 20)
      STDOUT.sync = true
      STDOUT.write("router#")
      abort unless STDIN.gets == "first\n"
      STDOUT.write("small\nrouter#")
      abort unless STDIN.gets == "second\n"
      STDOUT.write("larger-output\nrouter#")
      STDIN.read
    RUBY
    device.connect
    channel = transport.channel
    pid = channel.pid
    result = device.execute_script(["first", "second", "never"])
    assert_instance_of Connector::ScriptOutputLimitExceeded, result.error
    assert_equal "second", result.error.command
    assert_equal ["small\nrouter#", "larger-output\nrouter#"], result.steps.map(&:output)
    assert channel.closed?
    refute channel.alive?
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
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

    result = device.execute_command("show", timeout: 0.1)

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

    result = device.execute_command("show")

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

    result = device.execute_command("show size")

    assert result.success?, result.error&.message
    assert_equal "size=40,100\nrouter#", result.output
  ensure
    device&.close
  end

  def test_real_pty_configuration_output_is_private_and_logging_resumes_after_collection
    %i[raw text].each do |format|
      Dir.mktmpdir do |directory|
        secret = SecureRandom.hex(24)
        path = File.join(directory, "session.log")
        device, transport = local_device(<<~RUBY, log_file: path, log_format: format, log_level: :debug)
          $stdout.sync = true
          secret = #{secret.inspect}
          print "router#"
          abort unless $stdin.gets == "terminal length 0\\n"
          print "router#"
          abort unless $stdin.gets == "show running-config\\n"
          print "service opaque ", secret[0, 12]
          print "\\e[31m", secret[12..], "\\e[0m\\nrouter#"
          abort unless $stdin.gets == "show status\\n"
          print "ordinary output\\nrouter#"
          $stdin.read
        RUBY
        result = device.running_config
        assert result.success?, result.error.inspect
        assert_equal "service opaque #{secret}\nrouter#", result.config
        assert result.steps.last.command.output_sensitive?
        assert device.execute_command("show status").success?
        channel = transport.channel
        pid = channel.pid
        device.close
        contents = File.binread(path)
        [secret, secret[0, 12], secret[12..]].each { |part| refute_includes contents, part }
        assert_includes contents, "ordinary output"
        assert channel.closed?
        refute channel.alive?
        assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      ensure
        device&.close
      end
    end
  end

  def test_real_pty_configuration_timeout_hides_pending_output_and_reaps_child
    %i[raw text].each do |format|
      Dir.mktmpdir do |directory|
        secret = SecureRandom.hex(24)
        path = File.join(directory, "session.log")
        device, transport = local_device(<<~RUBY, log_file: path, log_format: format, log_level: :debug)
          $stdout.sync = true
          print "router#"
          abort unless $stdin.gets == "terminal length 0\\n"
          print "router#"
          abort unless $stdin.gets == "show running-config\\n"
          print #{secret.inspect}
          $stdin.read
        RUBY
        device.define_singleton_method(:config_commands) do
          [Connector::Command.new("terminal length 0"), Connector::Command.new("show running-config", timeout: 0.1)]
        end
        device.connect
        channel = transport.channel
        pid = channel.pid
        result = device.running_config
        assert_instance_of Connector::CommandTimeout, result.error
        assert_equal "show running-config", result.error.command
        assert_equal 1, result.steps.size
        [result.error.message, result.error.output, result.error.full_message, File.binread(path)].each do |text|
          refute_includes text, secret
        end
        assert_nil result.error.cause
        assert channel.closed?
        refute channel.alive?
        assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      ensure
        device&.close
      end
    end
  end

  private

  def with_cleanup_transport
    channels = []
    factory = -> { Expect::Session.new.tap { |channel| channels << channel } }
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "audit")
    script = 'trap("HUP", "IGNORE"); trap("TERM", "IGNORE"); STDOUT.sync = true; puts "ready"; loop { sleep 1 }'
    transport = LocalTransport.new(configuration, script, channel_factory: factory)
    transport.open
    assert channels.last.expect("ready", timeout: 5).matched?
    yield transport, channels
  ensure
    channels&.each { |channel| channel.hard_close(timeout: 0) }
    transport&.close
  end

  # 模拟 read_available 已追加正文后的回调，真实适配器仍负责预算与日志处理。
  def with_buffer_channel(logging: true)
    buffer, snapshots, transcript = +"", [], nil
    channel = Object.new
    channel.define_singleton_method(:buffer) { snapshots << buffer.bytesize; buffer.dup }
    channel.define_singleton_method(:buffer_bytesize) { buffer.bytesize }
    channel.define_singleton_method(:transcript=) { |writer| transcript = writer }
    channel.define_singleton_method(:spawn) { |*, **| }
    channel.define_singleton_method(:hard_close) {}
    channel.define_singleton_method(:alive?) { false }
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "audit", max_output_bytes: 4)
    transport = LocalTransport.new(configuration, "", channel_factory: -> { channel })
    log = StringIO.new
    transport.log_output = log if logging
    transport.open
    yield buffer, transcript, snapshots, log
  ensure
    transport&.close
  end

  def local_device(script, **options)
    configuration = Connector::Configuration.new(host: "192.0.2.1", username: "test",
                                                 login_timeout: 2, command_timeout: 2, **options)
    transport = LocalTransport.new(configuration, script)
    [Connector.build(:cisco_ios, configuration: configuration, transport: transport), transport]
  end
end
