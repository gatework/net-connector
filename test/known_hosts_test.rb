# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"
require "json"
require_relative "../lib/net/connector"

class KnownHostsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @destination = File.join(@directory, "known_hosts")
    @key = key("one")
    @new_key = key("two")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_initialization_keeps_original_failure_when_snapshot_cleanup_fails
    [IOError.new("snapshot failed"), Interrupt.new("snapshot interrupted")].each do |original|
      file = Tempfile.new(["snapshot-", ""], @directory)
      path = file.path
      close = file.method(:close!)
      closed = 0
      file.define_singleton_method(:write) { |*| raise original }
      file.define_singleton_method(:close!) { closed += 1; close.call; raise IOError, "cleanup failed" }
      config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination)
      Tempfile.stub(:new, file) do
        raised = assert_raises(original.class) { Net::Connector::KnownHosts.new(config) }
        assert_same original, raised
      end
      assert_equal 1, closed
      refute File.exist?(path)
    end
  end

  def test_commit_reports_directory_sync_failure_without_losing_the_registered_key
    entry = snapshot(1)
    contents = "192.0.2.1 #{@key}\n"
    File.write(entry.path, contents)
    open_file = File.method(:open)
    open = lambda do |path, *arguments, **options, &block|
      file = open_file.call(path, *arguments, **options)
      if file.stat.directory? && File.realpath(path) == File.realpath(@directory)
        file.define_singleton_method(:fsync) { raise Errno::EIO, "directory sync failed" }
      end
      next file unless block

      begin
        block.call(file)
      ensure
        file.close
      end
    end
    error = File.stub(:open, open) { assert_raises(Net::Connector::ConnectionError) { entry.commit } }
    assert_equal :file_persistence_unconfirmed, error.code
    assert_nil error.cause
    assert_equal contents, File.binread(@destination)
    assert_equal 0o600, File.stat(@destination).mode & 0o777
    assert_empty Dir[File.join(@directory, ".net-connector-*")]
  ensure
    entry&.close
  end

  def test_nonregular_shared_trust_is_a_domain_failure_and_is_not_replaced
    target = File.join(@directory, "target")
    File.write(target, "untouched")
    File.symlink(target, @destination)
    error = assert_raises(Net::Connector::ConnectionError) { snapshot(1) }
    assert_equal :known_hosts_unsafe, error.code
    assert_nil error.cause
    assert File.symlink?(@destination)
    assert_equal "untouched", File.read(target)
  end

  def test_merge_preserves_existing_duplicates_and_adds_each_new_line_once
    original = "192.0.2.9 #{@key}\n" * 2
    File.write(@destination, original)
    entry = snapshot(1)
    added = "192.0.2.1 #{@new_key}\n"
    File.write(entry.path, original + (added * 2))
    entry.commit
    assert_equal original + added, File.binread(@destination)
  ensure
    entry&.close
  end

  def test_close_removes_snapshot_even_when_old_file_removal_fails
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination)
    entry = Net::Connector::KnownHosts.new(config)
    path = entry.path
    File.write(path + ".old", "previous snapshot")
    original = IOError.new("old file removal failed")
    unlink = File.method(:unlink)
    File.stub(:unlink, ->(target) { target == path + ".old" ? (raise original) : unlink.call(target) }) do
      raised = assert_raises(IOError) { entry.close }
      assert_same original, raised
    end
    refute File.exist?(path)
    entry.close
    refute File.exist?(path + ".old")
  end

  def test_cancel_at_snapshot_handoff_releases_the_file
    file = Tempfile.new(["snapshot-", ""], @directory)
    path = file.path
    original = Interrupt.new("snapshot handoff cancelled")
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination)
    Tempfile.stub(:new, ->(*) { Thread.current.raise(original); file }) do
      assert_same original, assert_raises(Interrupt) { Net::Connector::KnownHosts.new(config) }
    end
    assert file.closed?
    refute File.exist?(path)
  ensure
    file&.close!
  end

  def test_snapshot_constructor_failure_precedes_deferred_cancellation
    original = IOError.new("snapshot construction failed")
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination)
    Tempfile.stub(:new, ->(*) { Thread.current.raise(Interrupt.new("secondary cancellation")); raise original }) do
      assert_same original, assert_raises(Exception) { Net::Connector::KnownHosts.new(config) }
    end
  end

  def test_cancel_during_snapshot_close_waits_for_removal
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination)
    entry = Net::Connector::KnownHosts.new(config)
    path = entry.path
    file = entry.instance_variable_get(:@file)
    close = file.method(:close!)
    original = Interrupt.new("snapshot close cancelled")
    file.define_singleton_method(:close!) { Thread.current.raise(original); close.call }
    assert_same original, assert_raises(Interrupt) { entry.close }
    refute File.exist?(path)
    assert file.closed?
  ensure
    close&.call
  end

  def test_snapshot_close_preserves_first_failure_before_deferred_cancellation
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination)
    entry = Net::Connector::KnownHosts.new(config)
    file = entry.instance_variable_get(:@file)
    close = file.method(:close!)
    original = IOError.new("snapshot close failed")
    file.define_singleton_method(:close!) do
      Thread.current.raise(Interrupt.new("secondary cancellation"))
      close.call
      raise original
    end
    assert_same original, assert_raises(IOError) { entry.close }
    assert file.closed?
    assert_nil original.cause
  ensure
    close&.call
  end

  def test_lock_wait_expires_without_changing_trust_and_can_be_retried_after_unlock
    original = "192.0.2.9 #{@key}\n"
    File.write(@destination, original)
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination,
                                               host_key_policy: :accept_new, login_timeout: 0.01)
    entry = Net::Connector::KnownHosts.new(config)
    File.open(entry.path, "a") { |file| file.puts "192.0.2.1 #{@new_key}" }
    worker = nil
    File.open(@destination + ".nc-lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      worker = Thread.new do
        entry.commit
      rescue StandardError => error
        error
      end
      assert worker.join(2), "known_hosts lock wait must be bounded"
      error = worker.value
      assert_instance_of Net::Connector::ConnectionError, error
      assert_equal :known_hosts_busy, error.code
      assert_equal :login, error.phase
      assert_equal original, File.read(@destination)
      lock.flock(File::LOCK_UN)
      entry.commit
      assert_includes File.read(@destination), "192.0.2.1 #{@new_key}"
      assert_includes File.read(@destination), original
    end
  ensure
    worker&.kill&.join if worker&.alive?
    entry&.close
  end

  def test_concurrent_processes_merge_replacements_and_new_hosts_without_losing_entries
    File.write(@destination, "192.0.2.1 #{@key}\n192.0.2.2 #{@key}\n192.0.2.9 #{@key}\n")
    readers = []
    processes = (1..3).map do |index|
      ready_read, ready_write = IO.pipe
      start_read, start_write = IO.pipe
      pid = fork do
        ready_read.close
        start_write.close
        entry = snapshot(index, replace: index < 3)
        File.open(entry.path, "a") { |file| file.puts "192.0.2.#{index} #{@new_key}" }
        ready_write.write("ready")
        ready_write.close
        start_read.read(1)
        entry.commit
        entry.close
        exit! 0
      end
      ready_write.close
      start_read.close
      readers << [ready_read, start_write]
      pid
    end
    readers.each { |reader, _writer| assert_equal "ready", reader.read }
    readers.each { |reader, writer| reader.close; writer.write("x"); writer.close }
    processes.each { |pid| assert Process.wait2(pid).last.success? }
    contents = File.read(@destination)
    (1..3).each { |index| assert_includes contents, "192.0.2.#{index} #{@new_key}" }
    refute_includes contents, "192.0.2.1 #{@key}"
    refute_includes contents, "192.0.2.2 #{@key}"
    assert_includes contents, "192.0.2.9 #{@key}"
    assert_equal 0o600, File.stat(@destination).mode & 0o777
    assert_empty Dir[File.join(@directory, ".nc-known-hosts-*")]
  end

  def test_inherited_close_preserves_parent_snapshot_and_backup
    entry = snapshot(1)
    path = entry.path
    contents = "192.0.2.1 #{@key}\n"
    File.write(path, contents)
    File.write(path + ".old", "parent backup")
    file = entry.instance_variable_get(:@file)

    assert_equal true, (fork_result { entry.close; entry.close; file.closed? })
    assert File.exist?(path), "child close must preserve the parent's snapshot"
    assert_equal "parent backup", File.read(path + ".old")
    refute file.closed?
    entry.commit
    assert_equal contents, File.read(@destination)
    entry.close
    refute File.exist?(path)
    refute File.exist?(path + ".old")
  ensure
    entry&.close
  end

  def test_inherited_commit_is_rejected_before_reading_or_changing_trust
    original = "192.0.2.9 #{@key}\n"
    File.write(@destination, original)
    entry = snapshot(1)
    [false, true].each do |changed|
      File.open(entry.path, "a") { |file| file.puts "192.0.2.1 #{@new_key}" } if changed
      [false, true].each do |closed|
        result = fork_result do
          entry.close if closed
          begin
            entry.commit
            { rejected: false }
          rescue Net::Connector::ConnectionError => error
            { rejected: true, code: error.code, phase: error.phase, cause: error.cause,
              diagnostic: Net::Connector::Error::Metadata.code(error.code) }
          end
        end
        assert_equal({ rejected: true, code: "known_hosts_inherited", phase: "login", cause: nil,
                       diagnostic: "known_hosts_inherited" }, result)
        assert_equal original, File.read(@destination)
        assert File.exist?(entry.path)
      end
    end
    entry.commit
    assert_includes File.read(@destination), "192.0.2.1 #{@new_key}"
  ensure
    entry&.close
  end

  def test_child_reopens_ssh_with_its_own_snapshot_and_preserves_parent_session
    transport = local_ssh_transport
    transport.open
    transport.read([/router#/], timeout: 2)
    parent_path = transport.instance_variable_get(:@known_hosts).path
    child = fork_result do
      transport.open
      transport.read([/router#/], timeout: 2)
      child_path = transport.instance_variable_get(:@known_hosts).path
      transport.authenticated
      transport.close
      { independent: child_path != parent_path, removed: !File.exist?(child_path) }
    end
    assert_equal({ independent: true, removed: true }, child)
    assert File.exist?(parent_path), "child reopen must preserve the parent's snapshot"
    transport.write("continue\n")
    event = transport.read([/router#/], timeout: 2)
    assert_equal 0, event.index
    transport.authenticated
    assert_equal "192.0.2.1 #{@key}\n", File.read(@destination)
    transport.close
    refute File.exist?(parent_path)
  ensure
    transport&.close
  end

  def test_failed_snapshot_close_is_retried_before_ssh_reopen
    transport = local_ssh_transport
    transport.open
    old_snapshot = transport.instance_variable_get(:@known_hosts)
    path = old_snapshot.path
    file = old_snapshot.instance_variable_get(:@file)
    close = file.method(:close!)
    first = true
    file.define_singleton_method(:close!) do
      if first
        first = false
        raise IOError, "snapshot close failed before closing"
      end
      close.call
    end
    assert_raises(IOError) { transport.close }
    assert File.exist?(path)
    refute file.closed?
    transport.open
    assert file.closed?, "reopen must retry the old snapshot descriptor"
    refute File.exist?(path)
    refute_equal path, transport.instance_variable_get(:@known_hosts).path
  ensure
    transport&.close
    close&.call
  end

  def test_silent_unlink_denial_keeps_snapshot_owned_for_close_or_reopen
    %i[close open].each do |action|
      transport = local_ssh_transport
      transport.open
      path = transport.instance_variable_get(:@known_hosts).path
      unlink = File.method(:unlink)
      File.stub(:unlink, ->(target) { target == path ? (raise Errno::EACCES) : unlink.call(target) }) do
        assert_raises(IOError) { transport.close }
      end
      assert File.exist?(path)
      transport.public_send(action)
      refute File.exist?(path), "cleanup ownership was lost after unlink denial"
      transport.close
    ensure
      transport&.close
    end
  end

  def test_failed_authentication_discards_replacement_without_changing_shared_trust
    original = "192.0.2.1 #{@key}\n"
    File.write(@destination, original)
    entry = snapshot(1, replace: true)
    File.write(entry.path, "192.0.2.1 #{@new_key}\n")
    entry.close
    assert_equal original, File.read(@destination)
  end

  def test_accept_new_rejects_a_different_key_registered_by_another_session
    first = snapshot(1)
    second = snapshot(1)
    File.write(first.path, "192.0.2.1 #{@key}\n")
    File.write(second.path, "192.0.2.1 #{@new_key}\n")
    first.commit
    error = assert_raises(Net::Connector::ConnectionError) { second.commit }
    assert_equal :host_key_changed, error.code
    assert_equal "192.0.2.1 #{@key}\n", File.read(@destination)
  ensure
    first&.close
    second&.close
  end

  def test_record_separator_cannot_hide_a_concurrent_host_key_change
    previous, field_separator, verbosity = $/, $;, $VERBOSE
    first = snapshot(1)
    second = snapshot(1)
    original = "192.0.2.1 #{@key}\n"
    File.write(first.path, original)
    File.write(second.path, "192.0.2.1 #{@new_key}\n")
    first.commit
    $VERBOSE = nil
    $/ = nil
    $; = ","
    error = assert_raises(Net::Connector::ConnectionError) { second.commit }
    assert_equal :host_key_changed, error.code
    assert_equal original, File.binread(@destination)
  ensure
    $/ = previous
    $; = field_separator
    $VERBOSE = verbosity
    first&.close
    second&.close
  end

  def test_nonstandard_port_and_unchanged_entries
    File.write(@destination, "[192.0.2.1]:2222 #{@key}\n192.0.2.1 #{@key}\n")
    entry = snapshot(1, replace: true, port: 2222)
    File.open(entry.path, "a") { |file| file.puts "[192.0.2.1]:2222 #{@new_key}" }
    entry.commit
    assert_includes File.read(@destination), "192.0.2.1 #{@key}"
    assert_includes File.read(@destination), "[192.0.2.1]:2222 #{@new_key}"
    same = snapshot(1)
    same.commit
  ensure
    entry&.close
    same&.close
  end

  def test_session_commits_the_staged_key_after_local_pty_authentication
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination,
                                               host_key_policy: :accept_new)
    transport_class = Class.new(Net::Connector::Transports::Ssh) do
      attr_accessor :key_line
      def argv
        destination = super.find { |argument| argument.start_with?("UserKnownHostsFile=") }.split("=", 2).last
        script = "STDOUT.sync = true; File.write(#{destination.inspect}, #{key_line.inspect}); puts 'router#'; STDIN.read"
        [RbConfig.ruby, "--disable-gems", "-e", script]
      end
    end
    transport = transport_class.new(config)
    transport.key_line = "192.0.2.1 #{@key}\n"
    device = Net::Connector.build(:cisco_ios, configuration: config, transport: transport)
    device.connect
    assert_equal transport.key_line, File.read(@destination)
    device.close
    assert_empty Dir[File.join(@directory, ".nc-known-hosts-*")]
  ensure
    device&.close
  end

  def test_session_replaces_changed_key_only_after_successful_retry
    original = "192.0.2.1 #{@key}\n192.0.2.9 #{@key}\n"
    File.write(@destination, original)
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination,
                                               host_key_policy: :replace)
    transport_class = Class.new(Net::Connector::Transports::Ssh) do
      attr_accessor :old_key, :new_key
      def argv
        destination = super.find { |argument| argument.start_with?("UserKnownHostsFile=") }.split("=", 2).last
        script = <<~CODE
          STDOUT.sync = true
          if File.read(#{destination.inspect}).include?(#{("192.0.2.1 " + old_key).inspect})
            puts 'REMOTE HOST IDENTIFICATION CHANGED'
          else
            File.open(#{destination.inspect}, 'a') { |file| file.puts #{("192.0.2.1 " + new_key).inspect} }
            puts 'router#'
          end
          STDIN.read
        CODE
        [RbConfig.ruby, "--disable-gems", "-e", script]
      end
    end
    transport = transport_class.new(config)
    transport.old_key, transport.new_key = @key, @new_key
    device = Net::Connector.build(:cisco_ios, configuration: config, transport: transport)
    device.connect
    contents = File.read(@destination)
    assert_includes contents, "192.0.2.1 #{@new_key}"
    refute_includes contents, "192.0.2.1 #{@key}"
    assert_includes contents, "192.0.2.9 #{@key}"
  ensure
    device&.close
  end

  private

  def fork_result
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      begin
        writer.write(JSON.generate(result: yield))
        writer.close
        exit! 0
      rescue StandardError => error
        writer.write(JSON.generate(error: [error.class.name, error.message]))
        writer.close
        exit! 1
      end
    end
    writer.close
    result, status = Timeout.timeout(10) { [JSON.parse(reader.read, symbolize_names: true), Process.wait2(pid).last] }
    pid = nil
    assert status.success?, "child failed: #{result[:error].inspect}"
    result.fetch(:result)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  def local_ssh_transport
    config = Net::Connector::Configuration.new(host: "192.0.2.1", username: "audit", known_hosts: @destination,
                                               host_key_policy: :accept_new)
    transport_class = Class.new(Net::Connector::Transports::Ssh) do
      attr_accessor :key_line

      def argv
        path = super.find { |argument| argument.start_with?("UserKnownHostsFile=") }.split("=", 2).last
        script = "STDOUT.sync = true; File.write(#{path.inspect}, #{key_line.inspect}); puts 'router#'; " \
                 "STDIN.each_line { puts 'router#' }"
        [RbConfig.ruby, "--disable-gems", "-e", script]
      end
    end
    transport_class.new(config).tap { |transport| transport.key_line = "192.0.2.1 #{@key}\n" }
  end

  def key(name)
    path = File.join(@directory, name)
    _output, status = Open3.capture2e("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", path)
    raise "key generation failed" unless status.success?

    File.read(path + ".pub").split.first(2).join(" ")
  end

  def snapshot(index, replace: false, port: nil)
    config = Net::Connector::Configuration.new(host: "192.0.2.#{index}", username: "audit", port: port,
                                               known_hosts: @destination, host_key_policy: replace ? :replace : :accept_new)
    Net::Connector::KnownHosts.new(config, replace: replace)
  end
end
