# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"
require "stringio"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class BackupLockTest < Minitest::Test
  Storage = Net::Connector::Storage
  LocalBackup = Net::Connector::LocalBackup

  def collector(&block)
    Object.new.tap do |device|
      device.define_singleton_method(:host) { "192.0.2.1" }
      device.define_singleton_method(:running_config) { Net::Connector::Result.new(config: block.call) }
    end
  end

  def backup(device, path, **options) = LocalBackup.new(device).call(path: path, **options)

  def test_two_instances_contend_before_collecting_and_leave_a_stable_private_lock
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      entered, release = Queue.new, Queue.new
      first = collector { entered << true; release.pop; "first configuration" }
      calls = 0
      second = collector { calls += 1; "second configuration" }
      owner = Thread.new { backup(first, path) }
      begin
        Timeout.timeout(3) { entered.pop }
        error = assert_raises(Net::Connector::Error) { backup(second, path) }
        assert_equal :backup_busy, error.code
        assert_equal 0, calls
        refute File.exist?(path)
      ensure
        release << true
        owner.join(3) || owner.kill.join
      end
      owner.value
      lock_path = Storage::BackupLock.lock_path(path)
      stat = File.stat(lock_path)
      assert_equal 0o600, stat.mode & 0o777
      assert_equal 1, stat.nlink
      assert_equal "first configuration", File.binread(path)
      assert_equal :changed, backup(second, path).change
      assert_equal "second configuration", File.binread(path)
      assert_equal [stat.dev, stat.ino], [File.stat(lock_path).dev, File.stat(lock_path).ino]
    end
  end

  def test_directory_aliases_share_a_lock_and_other_targets_can_progress
    Dir.mktmpdir do |root|
      directory = File.join(root, "actual")
      Dir.mkdir(directory)
      Dir.mkdir(File.join(directory, "sub"))
      File.symlink(directory, File.join(root, "alias"))
      path = File.join(directory, "device.txt")
      aliases = [File.join(directory, "sub", "..", "device.txt"), File.join(root, "alias", "device.txt")]
      Storage::BackupLock.synchronize(path) do
        aliases.each do |candidate|
          assert_equal Storage::BackupLock.lock_path(path), Storage::BackupLock.lock_path(candidate)
          error = Fiber.new { assert_raises(Net::Connector::Error) { backup(collector { flunk "collected while busy" }, candidate) } }.resume
          assert_equal :backup_busy, error.code
        end
        other = File.join(directory, "other.txt")
        assert_equal :created, backup(collector { "independent" }, other).change
      end
    end
  end

  def test_collection_failure_and_nonlocal_exit_release_the_lock
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      File.write(path, "old")
      assert_raises(IOError) { backup(collector { raise IOError, "fixture failure" }, path) }
      assert_equal :stopped, catch(:stop) { backup(collector { throw :stop, :stopped }, path) }
      assert_equal "old", File.read(path)
      assert_equal :changed, backup(collector { "new" }, path).change
    end
  end

  def test_filename_case_and_unicode_aliases_contend_even_before_destination_exists
    Dir.mktmpdir do |directory|
      path = File.join(directory, "D\u00e9vice.TXT")
      aliases = [File.join(directory, "d\u00e9vice.txt"), File.join(directory, "De\u0301vice.TXT"), path.b]
      Storage::BackupLock.synchronize(path) do
        aliases.each do |candidate|
          assert_equal Storage::BackupLock.lock_path(path), Storage::BackupLock.lock_path(candidate)
          error = Fiber.new do
            assert_raises(Net::Connector::Error) { backup(collector { flunk "collected through filename alias" }, candidate) }
          end.resume
          assert_equal :backup_busy, error.code
        end
        refute File.exist?(path)
      end
    end
  end

  def test_lock_rejects_hardlinks_and_fifo_without_blocking
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      lock_path = Storage::BackupLock.lock_path(path)
      outside = File.join(directory, "outside")
      File.write(outside, "unchanged", mode: "w", perm: 0o600)
      File.link(outside, lock_path)
      device = collector { flunk "invalid lock reached collection" }
      assert_raises(ArgumentError) { backup(device, path) }
      assert_equal "unchanged", File.read(outside)
      File.unlink(lock_path)
      File.mkfifo(lock_path, 0o600)
      Timeout.timeout(3) { assert_raises(ArgumentError) { backup(device, path) } }
    end
  end

  def test_unchanged_read_does_not_leave_a_symlink_swapped_in_after_open
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      outside = File.join(directory, "outside")
      File.write(path, "same configuration", mode: "w", perm: 0o600)
      File.write(outside, "unrelated data")
      original = File.method(:open)
      swapped = false
      intercept = lambda do |target, *args, **options, &block|
        next original.call(target, *args, **options, &block) unless target == path && !swapped

        file = original.call(target, *args, **options)
        File.unlink(path)
        File.symlink(outside, path)
        swapped = true
        file
      end
      result = File.stub(:open, intercept) { backup(collector { "same configuration" }, path) }
      assert_equal :unchanged, result.change
      assert swapped
      refute File.symlink?(path)
      assert_equal "same configuration", File.read(path)
      assert_equal "unrelated data", File.read(outside)
    end
  end

  def test_fleet_contention_fails_before_credentials_and_connector_construction
    Dir.mktmpdir do |directory|
      netdisco = Net::Connector::Netdisco
      client = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      fleet = netdisco::Fleet.new(client: client, settings: netdisco::Settings.new(env: {}), result_store: nil,
                                 credentials: ->(*) { flunk "read credentials while path busy" },
                                 connector_factory: ->(*) { flunk "created connector while path busy" })
      path = File.join(directory, "192.0.2.1.txt")
      Storage::BackupLock.synchronize(path) do
        batch = fleet.backup_all(directory: directory)
        assert_equal :failed, batch.outcomes.first.status
        assert_equal :backup_busy, batch.outcomes.first.error_code
        assert_nil batch.outcomes.first.backup
        refute File.exist?(path)
      end
    end
  end

  def test_recursive_backup_in_the_same_fiber_cannot_borrow_path_ownership
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      calls = 0
      competing = collector { calls += 1; "competing configuration" }
      owner = collector do
        error = assert_raises(Net::Connector::Error) { backup(competing, path) }
        assert_equal :backup_busy, error.code
        "owner configuration"
      end
      assert_equal :created, backup(owner, path).change
      assert_equal 0, calls
      assert_equal "owner configuration", File.read(path)
    end
  end

  def test_lock_wait_is_finite_and_uses_one_monotonic_deadline
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      Storage::BackupLock.synchronize(path) {}
      File.open(Storage::BackupLock.lock_path(path), File::RDWR) do |owner|
        owner.flock(File::LOCK_EX)
        waiter = Storage::BackupLock.new(path, timeout: 0.1)
        now = 10.0
        waits = []
        waiter.stub(:monotonic, -> { now }) do
          waiter.stub(:wait, ->(seconds) { waits << seconds; now += seconds }) do
            error = assert_raises(Net::Connector::Error) { waiter.synchronize { flunk "acquired held lock" } }
            assert_equal :backup_busy, error.code
          end
        end
        assert_in_delta 0.1, waits.sum, 0.000001
        waiter = Storage::BackupLock.new(path, timeout: 1)
        waiter.stub(:wait, ->(_seconds) { owner.flock(File::LOCK_UN) }) do
          assert_equal :acquired, (waiter.synchronize { :acquired })
        end
      end
    end
  end

  def test_invalid_wait_settings_and_lock_files_fail_before_collection
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      device = collector { flunk "invalid lock reached collection" }
      [-1, Float::INFINITY, Float::NAN, nil, true, "1"].each do |timeout|
        assert_raises(ArgumentError) { backup(device, path, lock_timeout: timeout) }
      end
      Storage::BackupLock.synchronize(path) {}
      lock_path = Storage::BackupLock.lock_path(path)
      File.chmod(0o644, lock_path)
      assert_raises(ArgumentError) { backup(device, path) }
      File.unlink(lock_path)
      outside = File.join(directory, "outside")
      File.write(outside, "unchanged")
      File.symlink(outside, lock_path)
      assert_raises(ArgumentError) { backup(device, path) }
      assert_equal "unchanged", File.read(outside)
      File.unlink(lock_path)
      Dir.mkdir(lock_path)
      assert_raises(ArgumentError) { backup(device, path) }
    end
  end

  def test_direct_backup_replaces_final_symlink_without_reading_its_target
    Dir.mktmpdir do |directory|
      outside = File.join(directory, "outside")
      File.write(outside, "unrelated data")
      path = File.join(directory, "device.txt")
      File.symlink(outside, path)
      result = backup(collector { "collected data" }, path)
      assert_equal :created, result.change
      assert_nil result.previous_sha256
      refute File.symlink?(path)
      assert_equal "collected data", File.read(path)
      assert_equal "unrelated data", File.read(outside)
    end
  end

  def test_path_is_copied_before_collection
    Dir.mktmpdir do |directory|
      original = File.join(directory, "device.txt")
      supplied = original.dup
      alternate = File.join(directory, "changed.txt")
      result = backup(collector { supplied.replace(alternate); "collected data" }, supplied)
      assert_equal original, result.path
      assert_equal "collected data", File.read(original)
      refute File.exist?(alternate)
    end
  end

  def test_backup_does_not_acquire_path_lock_inside_an_owned_session
    device = Net::Connector.build(:h3c, host: "192.0.2.1", username: "backup", transport: ConnectorFake.new)
    Dir.mktmpdir do |directory|
      device.with_operation(:test) do
        error = assert_raises(Net::Connector::SessionBusy) { device.backup(path: File.join(directory, "device.txt")) }
        assert_equal :backup, error.phase
      end
      assert_empty Dir.children(directory)
    end
  ensure
    device&.close
  end

  def test_separate_ruby_process_owns_the_same_lock_until_collection_and_write_finish
    script = <<~'RUBY'
      require "net/connector"
      STDOUT.sync = true
      device = Object.new
      def device.running_config
        puts "collecting"
        STDIN.gets or abort "missing release signal"
        Net::Connector::Result.new(config: "child configuration")
      end
      Net::Connector::LocalBackup.new(device).call(path: ARGV.fetch(0))
      puts "done"
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "device.txt")
      Open3.popen3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, path) do |input, output, error, process|
        begin
          assert_equal "collecting\n", Timeout.timeout(5) { output.gets }
          failure = assert_raises(Net::Connector::Error) { backup(collector { flunk "parent collected while child owned path" }, path) }
          assert_equal :backup_busy, failure.code
          refute File.exist?(path)
          input.puts "release"
          assert_equal "done\n", Timeout.timeout(5) { output.gets }
          assert process.value.success?, error.read
          assert_equal "child configuration", File.read(path)
          assert_equal :changed, backup(collector { "parent configuration" }, path).change
        ensure
          input.close unless input.closed?
          unless process.join(2)
            Process.kill("TERM", process.pid)
            process.join
          end
        end
      end
    end
  end

  def test_saved_config_rejects_symlink_swapped_in_at_open_and_never_reads_the_target
    Dir.mktmpdir do |directory|
      path = File.join(directory, "192.0.2.1.txt")
      outside = File.join(directory, "outside")
      File.write(path, "approved")
      File.write(outside, "unregistered-test-secret")
      saved = Storage::SavedConfig.new(directory: directory)
      real_open = File.method(:open)
      swapped = false
      intercept = lambda do |target, *args, **options, &block|
        if target == path && !swapped
          swapped = true
          File.unlink(path)
          File.symlink(outside, path)
        end
        real_open.call(target, *args, **options, &block)
      end
      output = StringIO.new
      File.stub(:open, intercept) { assert_raises(ArgumentError) { saved.export(host: "192.0.2.1", io: output) } }
      assert swapped
      assert_empty output.string
      assert_equal "unregistered-test-secret", File.read(outside)
    end
  end

  def test_safe_read_uses_the_opened_descriptor_even_when_the_path_is_replaced
    Dir.mktmpdir do |directory|
      path = File.join(directory, "192.0.2.1.txt")
      outside = File.join(directory, "outside")
      File.write(path, "approved")
      File.write(outside, "unregistered-test-secret")
      real_open = File.method(:open)
      opened = []
      intercept = lambda do |target, *args, **options, &block|
        next real_open.call(target, *args, **options, &block) unless target == path

        file = real_open.call(target, *args, **options)
        opened << file
        File.unlink(path)
        File.symlink(outside, path)
        file
      end
      output = StringIO.new
      File.stub(:open, intercept) { Storage::SavedConfig.new(directory: directory).export(host: "192.0.2.1", io: output) }
      assert_equal "approved", output.string
      assert_equal 1, opened.size
      assert opened.all?(&:closed?)
    end
  end
end
