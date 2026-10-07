# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "open3"
require "rbconfig"
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
