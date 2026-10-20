# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "securerandom"
require_relative "../lib/net/connector/netdisco"

class FilePersistenceTest < Minitest::Test
  Storage = Net::Connector::Storage
  LocalBackup = Net::Connector::LocalBackup
  AtomicFile = Storage::AtomicFile
  Netdisco = Net::Connector::Netdisco

  class ExternalWriteError < AtomicFile::PersistenceError
    def message = underlying_type
  end

  def setup
    @secret = "fixture-#{SecureRandom.hex(12)}"
  end

  def assert_safe(error)
    assert_nil error.cause
    refute_includes error.message, @secret
    refute_includes error.full_message, @secret
    refute_includes error.inspect, @secret
  end

  def test_success_returns_a_durable_write_receipt
    Dir.mktmpdir do |directory|
      path = File.join(directory, "data.txt")
      receipt = AtomicFile.write(path, "first")
      assert_equal path, receipt.path
      assert_equal :durable, receipt.state
      assert_equal :complete, receipt.phase
      assert receipt.committed?
      assert receipt.durable?
      assert receipt.frozen?
      assert receipt.path.frozen?
      assert AtomicFile.write(path, "second").durable?
      assert_equal "second", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_temporary_creation_write_flush_and_file_sync_fail_before_replacement
    { create: :temporary_file, write: :write, flush: :file_sync, fsync: :file_sync }.each do |operation, phase|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "data.txt")
        File.write(path, "old")
        failure = with_temporary_failure(operation) do
          assert_raises(IOError) { AtomicFile.write(path, @secret) }
        end
        assert_equal :not_committed, failure.receipt.state
        assert_equal phase, failure.receipt.phase
        refute failure.receipt.committed?
        assert_equal :file_write_failed, failure.code
        assert_equal "Errno::EIO", failure.underlying_type
        assert_equal "old", File.read(path)
        assert_equal ["data.txt"], Dir.children(directory)
        assert_safe(failure)
      end
    end
  end

  def test_failed_rename_keeps_the_old_file_and_does_not_claim_commit
    Dir.mktmpdir do |directory|
      path = File.join(directory, "data.txt")
      File.write(path, "old")
      File.stub(:rename, ->(*) { raise Errno::EIO, @secret }) do
        error = assert_raises(IOError) { AtomicFile.write(path, "new") }
        assert_equal :not_committed, error.receipt.state
        assert_equal :rename, error.receipt.phase
        assert_equal "old", File.read(path)
        assert_equal ["data.txt"], Dir.children(directory)
        assert_safe(error)
      end
    end
  end

  def test_directory_sync_error_reports_committed_data_and_clears_raw_cause
    Dir.mktmpdir do |directory|
      path = File.join(directory, "data.txt")
      File.write(path, "old")
      failure = with_directory_sync_failure(directory) do
        assert_raises(IOError) { AtomicFile.write(path, "new") }
      end
      assert_instance_of AtomicFile::PersistenceError, failure
      assert_equal :committed, failure.receipt.state
      assert_equal :directory_sync, failure.receipt.phase
      assert_equal :file_persistence_unconfirmed, failure.code
      refute failure.receipt.durable?
      assert_equal "new", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal ["data.txt"], Dir.children(directory)
      assert_safe(failure)
    end
  end

  def test_unsupported_directory_sync_is_distinguished_from_io_failure
    [Errno::EINVAL, Errno::ENOTSUP, NotImplementedError].each do |exception|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "data.txt")
        failure = with_directory_sync_failure(directory, exception: exception) do
          assert_raises(IOError) { AtomicFile.write(path, "new") }
        end
        assert_instance_of AtomicFile::DirectorySyncUnsupported, failure
        assert_equal :directory_sync_unsupported, failure.code
        assert_equal :committed, failure.receipt.state
        assert_equal "new", File.read(path)
        assert_safe(failure)
      end
    end
  end

  def test_parent_open_failure_is_committed_and_cleanup_failure_preserves_durable_state
    Dir.mktmpdir do |directory|
      path = File.join(directory, "data.txt")
      original = File.method(:open)
      parent = File.realpath(directory)
      open = lambda do |target, *args, **options, &block|
        raise Errno::EIO, @secret if target == parent

        original.call(target, *args, **options, &block)
      end
      error = File.stub(:open, open) { assert_raises(IOError) { AtomicFile.write(path, "committed") } }
      assert_equal :committed, error.receipt.state
      assert_equal :directory_open, error.receipt.phase
      assert_equal "committed", File.read(path)
      assert_safe(error)

      create = Tempfile.method(:create)
      cleanup = lambda do |*args, **options, &block|
        create.call(*args, **options, &block)
        raise Errno::EIO, @secret
      end
      error = Tempfile.stub(:create, cleanup) { assert_raises(IOError) { AtomicFile.write(path, "durable") } }
      assert_equal :durable, error.receipt.state
      assert_equal :cleanup, error.receipt.phase
      assert_equal :file_finalize_failed, error.code
      assert_equal "durable", File.read(path)
      assert_safe(error)
    end
  end

  def test_protocol_orders_file_sync_rename_and_directory_sync
    Dir.mktmpdir do |directory|
      path = File.join(directory, "data.txt")
      events = []
      create = Tempfile.method(:create)
      rename = File.method(:rename)
      create_probe = lambda do |*args, **options, &block|
        create.call(*args, **options) do |file|
          %i[write flush fsync].each do |method|
            original = file.method(method)
            file.define_singleton_method(method) { |*values| events << method; original.call(*values) }
          end
          block.call(file)
        end
      end
      rename_probe = ->(*args) { events << :rename; rename.call(*args) }
      Tempfile.stub(:create, create_probe) do
        File.stub(:rename, rename_probe) do
          with_directory_sync_probe(directory, ->(file) { events << :directory_sync; file.fsync }) do
            AtomicFile.write(path, "new")
          end
        end
      end
      assert_equal %i[write flush fsync rename directory_sync], events.first(5)
      assert_equal 1, events.count(:rename)
      assert_equal 1, events.count(:directory_sync)
    end
  end

  def test_local_backup_error_carries_committed_metadata_without_configuration_output
    Dir.mktmpdir do |directory|
      path = File.join(directory, "data.txt")
      File.write(path, "old")
      calls = 0
      device = local_device { calls += 1; @secret }
      failure = with_directory_sync_failure(directory) do
        assert_raises(Net::Connector::Error) { LocalBackup.new(device).call(path: path) }
      end
      assert_instance_of Net::Connector::BackupPersistenceError, failure
      assert_equal :backup_persistence_unconfirmed, failure.code
      assert_equal :committed, failure.receipt.state
      assert_equal path, failure.backup.path
      assert_equal @secret.bytesize, failure.backup.bytes
      assert_equal Digest::SHA256.hexdigest(@secret), failure.backup.sha256
      assert_equal Digest::SHA256.hexdigest("old"), failure.backup.previous_sha256
      assert_equal :changed, failure.backup.change
      assert_equal 1, calls
      assert_equal @secret, File.binread(path)
      assert_empty failure.output
      assert_safe(failure)
      # 错误后的路径锁已释放；相同内容重试无需重新写入，也不伪造上次的 durable 回执。
      assert_equal :unchanged, LocalBackup.new(device).call(path: path).change
    end
  end

  def test_fleet_preserves_committed_backup_and_current_baseline_as_partial_success
    Dir.mktmpdir do |directory|
      previous = File.join(directory, "192.0.2.1.txt")
      File.write(previous, "old")
      connector = local_device { @secret }
      closes = 0
      connector.define_singleton_method(:close) { closes += 1; raise IOError, "secondary close error" }
      fleet = fleet_for(connector)
      batch = with_directory_sync_failure(directory) { fleet.backup_all(directory: directory) }
      item = batch.outcomes.first
      refute batch.success?
      assert_equal :saved_with_error, item.status
      assert_equal :backup_persistence_unconfirmed, item.error_code
      assert_equal 1, batch.summary.fetch(:partial)
      assert_equal 0, batch.summary.fetch(:failed)
      assert_equal Digest::SHA256.hexdigest("old"), item.backup.previous_sha256
      assert_equal :changed, item.backup.change
      assert_equal 1, closes
      assert_equal @secret, File.binread(item.backup.path)
      refute_includes batch.summary.to_json, @secret
    end
  end

  def test_fleet_does_not_trust_an_arbitrary_exception_with_a_backup_attribute
    backup = Net::Connector::Backup.new(path: "untrusted", bytes: 1, sha256: "test", collected_at: Time.now.utc)
    error = IOError.new(@secret)
    error.define_singleton_method(:backup) { backup }
    connector = local_device { "unused" }
    connector.define_singleton_method(:backup) { |**_options| raise error }
    Dir.mktmpdir do |directory|
      batch = fleet_for(connector).backup_all(directory: directory)
      assert_equal :failed, batch.outcomes.first.status
      assert_nil batch.outcomes.first.backup
      refute_includes batch.summary.to_json, @secret
    end
  end

  def test_fleet_accepts_only_the_builtin_backup_finalize_error
    backup = Net::Connector::Backup.new(path: "retained.txt", bytes: 1, sha256: "fixture", collected_at: Time.now.utc)
    error_type = Net::Connector::BackupFinalizeError
    assert_raises(ArgumentError) { error_type.new(backup: Object.new, underlying: IOError.new) }
    [error_type, Class.new(error_type)].each do |type|
      error = type.new(backup: backup, underlying: IOError.new(@secret))
      connector = local_device { "unused" }
      connector.define_singleton_method(:backup) { |**| raise error, cause: nil }
      Dir.mktmpdir do |directory|
        report = fleet_for(connector).backup_all(directory: directory)
        value = report.outcomes.first
        if type == error_type
          assert_equal :saved_with_error, value.status
          assert_same backup, value.backup
          assert_equal :finalize, value.diagnostic.artifact_phase
          assert_equal "IOError", value.diagnostic.underlying_type
          assert_nil value.diagnostic.artifact_state
        else
          assert_equal :failed, value.status
          assert_nil value.backup
        end
        refute_includes JSON.generate(report.summary), @secret
      end
    end
  end

  def test_fleet_path_delegation_is_consumed_before_collecting
    Dir.mktmpdir do |directory|
      path = File.join(directory, "192.0.2.1.txt")
      calls = 0
      competing = local_device { calls += 1; "competing" }
      owner = local_device do
        error = assert_raises(Net::Connector::Error) { competing.backup(path: path) }
        assert_equal :backup_busy, error.code
        "owner"
      end
      batch = fleet_for(owner).backup_all(directory: directory)
      assert batch.success?
      assert_equal :backed_up, batch.outcomes.first.status
      assert_equal 0, calls
      assert_equal "owner", File.read(path)
    end
  end

  def test_report_keeps_its_committed_location_when_directory_sync_fails
    Dir.mktmpdir do |directory|
      fleet = fleet_for(local_device { "configuration" }, report_store: Netdisco::Report::Store::Json.new)
      batch = with_directory_sync_failure(directory, fail_on: 2) { fleet.backup_all(directory: directory) }
      refute batch.success?
      assert_equal :backed_up, batch.outcomes.first.status
      assert_equal "Net::Connector::Storage::AtomicFile::PersistenceError", batch.report_error
      refute_nil batch.report_location
      assert_equal batch.outcomes.first.backup.path,
                   JSON.parse(File.read(batch.report_location)).fetch("devices").first.fetch("path")
      assert_equal 0o600, File.stat(batch.report_location).mode & 0o777
    end
  end

  def test_external_write_error_subclasses_do_not_supply_trusted_receipts_or_messages
    Dir.mktmpdir do |directory|
      target = File.join(directory, "unwritten.txt")
      receipt = AtomicFile::Receipt.new(path: target, state: :committed, phase: :directory_sync)
      error = ExternalWriteError.new(receipt: receipt, underlying_type: @secret)
      backup = Net::Connector::Backup.new(path: target, bytes: 1, sha256: "test", collected_at: Time.now.utc)
      assert_raises(ArgumentError) { Net::Connector::BackupPersistenceError.new(backup: backup, write_error: error) }

      store = Object.new
      store.define_singleton_method(:write) { |*_, **_options| raise error }
      batch = fleet_for(local_device { "configuration" }, report_store: store).backup_all(directory: directory)
      assert_equal "StandardError", batch.report_error
      assert_nil batch.report_location
      refute batch.success?

      output, stderr = StringIO.new, StringIO.new
      status = AtomicFile.stub(:write, ->(*) { raise error }) do
        Netdisco::CLI.new(configuration_options: { directories: [] }, argv: ["--directory", directory, "--export", "192.0.2.1", "--output", target],
                          env: {}, output: output, error: stderr).run
      end
      assert_equal 2, status
      assert_empty output.string
      refute_includes stderr.string, @secret
      refute File.exist?(target)
    end
  end

  def test_export_surfaces_committed_state_and_cli_does_not_print_configuration
    Dir.mktmpdir do |directory|
      source = File.join(directory, "192.0.2.1.txt")
      target = File.join(directory, "export.cfg")
      File.write(source, @secret)
      output, error = StringIO.new, StringIO.new
      status = with_directory_sync_failure(directory) do
        Netdisco::CLI.new(configuration_options: { directories: [] }, argv: ["--directory", directory, "--export", "192.0.2.1", "--output", target],
                          env: {}, output: output, error: error, fleet_factory: ->(*) { flunk "export accessed inventory" }).run
      end
      assert_equal 2, status
      assert_equal @secret, File.read(target)
      assert_empty output.string
      assert_includes error.string, "committed"
      refute_includes error.string, @secret
    end
  end

  private

  def local_device(&contents)
    Object.new.tap do |device|
      device.define_singleton_method(:host) { "192.0.2.1" }
      device.define_singleton_method(:running_config) { Net::Connector::Result.new(config: contents.call) }
      device.define_singleton_method(:backup) { |path:| LocalBackup.new(self).call(path: path) }
      device.define_singleton_method(:close) {}
    end
  end

  def fleet_for(connector, report_store: nil)
    inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
    Netdisco::Fleet.new(inventory: inventory, settings: Netdisco::Settings.new(env: {}), report_store: report_store,
                        credentials: ->(*) { { username: "test" } }, connector_factory: ->(*) { connector })
  end

  def with_temporary_failure(operation, &block)
    failure = ->(*) { raise Errno::EIO, @secret }
    return Tempfile.stub(:create, failure, &block) if operation == :create

    original = Tempfile.method(:create)
    create = lambda do |*args, **options, &block|
      original.call(*args, **options) { |file| file.stub(operation, failure) { block.call(file) } }
    end
    Tempfile.stub(:create, create, &block)
  end

  def with_directory_sync_failure(directory, exception: Errno::EIO, fail_on: 1, &block)
    calls = 0
    probe = lambda do |file|
      calls += 1
      raise exception, @secret if calls == fail_on

      file.fsync
    end
    with_directory_sync_probe(directory, probe, &block)
  end

  def with_directory_sync_probe(directory, probe, &block)
    original = File.method(:open)
    canonical = File.realpath(directory)
    open = lambda do |path, *args, **options, &block|
      next original.call(path, *args, **options, &block) unless path == canonical || path == directory

      original.call(path, *args, **options) do |file|
        sync = file.method(:fsync)
        adapter = Object.new
        adapter.define_singleton_method(:fsync) { sync.call }
        file.stub(:fsync, -> { probe.call(adapter) }) { block.call(file) }
      end
    end
    File.stub(:open, open, &block)
  end
end
