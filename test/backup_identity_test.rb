# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "digest"
require_relative "../lib/net/connector/netdisco"
require_relative "../lib/net/connector/storage/saved_config"
require_relative "support/fake_transport"

class BackupIdentityTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  SavedConfig = Net::Connector::Storage::SavedConfig
  CONFIG = "sysname sw\ninterface GigabitEthernet1/0/1\n#\n[sw]"

  def fleet(inventory, config: CONFIG, **options)
    Netdisco::Fleet.new(inventory: inventory, settings: Netdisco::Settings.new(env: {}), report_store: nil,
                        credentials: ->(_) { { username: "backup" } },
                        connector_factory: ->(device, settings) {
                          device.build_connector(**settings, transport: ConnectorFake.new("[sw]", config))
                        }, **options)
  end

  def inventory(name: "new-name", host: "192.0.2.1")
    Struct.new(:devices).new([{ "ip" => host, "vendor" => "H3C", "name" => name }])
  end

  # 新增的持久路径锁是文件协议的一部分；仅排除当前目标的这一项，其他多余文件仍会失败。
  def backup_entries(directory, host: "192.0.2.1")
    path = File.join(directory, SavedConfig.filename(host))
    Dir.children(directory) - [File.basename(Net::Connector::Storage::BackupLock.lock_path(path))]
  end

  def test_backup_owns_metadata_on_construction_and_update
    path = +"/backups/device.txt"
    digest = +"original-digest"
    previous = +"previous-digest"
    collected_at = Time.utc(2026, 10, 17)
    backup = Net::Connector::Backup.new(path: path, bytes: 1, sha256: digest, collected_at: collected_at,
                                        previous_sha256: previous)
    path.replace("changed")
    digest.replace("changed")
    previous.replace("changed")
    collected_at.localtime("+12:00")
    assert_equal "/backups/device.txt", backup.path
    assert_equal "original-digest", backup.sha256
    assert_equal "previous-digest", backup.previous_sha256
    assert backup.collected_at.utc?
    [backup.path, backup.sha256, backup.previous_sha256, backup.collected_at].each { |value| assert_predicate value, :frozen? }

    updated_digest = +"updated-digest"
    updated_time = Time.utc(2026, 10, 18)
    updated = backup.with(sha256: updated_digest, collected_at: updated_time)
    updated_digest.replace("changed")
    updated_time.localtime("+12:00")
    assert_equal "updated-digest", updated.sha256
    assert updated.collected_at.utc?
    assert_predicate updated.sha256, :frozen?
    assert_predicate updated.collected_at, :frozen?
  end

  def test_result_callbacks_cannot_rewrite_persisted_backup_evidence
    Dir.mktmpdir do |directory|
      attempted = []
      callback = lambda do |outcome|
        assert_raises(FrozenError) { outcome.backup.sha256.replace("rewritten") }
        assert_raises(FrozenError) { outcome.backup.collected_at.localtime("+12:00") }
        assert_raises(FrozenError) { outcome.finished_at.localtime("+12:00") }
        attempted << outcome
      end
      report = fleet(inventory).backup_all(directory: directory, on_result: callback)
      assert report.success?, report.callback_errors.inspect
      assert_equal report.outcomes, attempted
      entry = report.summary.fetch(:devices).first
      assert_equal Digest::SHA256.file(entry.fetch(:path)).hexdigest, entry.fetch(:sha256)
      assert report.outcomes.first.finished_at.utc?
    end
  end

  def test_renaming_inventory_keeps_one_backup_and_its_change_baseline
    inventory = inventory(name: "old-name")
    collector = fleet(inventory)
    changes = []
    Dir.mktmpdir do |directory|
      first = collector.backup_all(directory: directory, on_change: ->(outcome) { changes << outcome.backup.change })
      assert first.success?, first.outcomes.inspect
      inventory.devices.first["name"] = "new-name"
      second = collector.backup_all(directory: directory, on_change: ->(outcome) { changes << outcome.backup.change })
      assert second.success?, second.outcomes.inspect

      backup = second.outcomes.first.backup
      assert_equal :unchanged, backup.change
      assert_equal first.outcomes.first.backup.sha256, backup.previous_sha256
      assert_equal File.join(directory, "192.0.2.1.txt"), backup.path
      assert_equal ["192.0.2.1.txt"], backup_entries(directory)
      assert_equal [:created], changes
      assert_equal "new-name", second.outcomes.first.device.name
      assert_equal backup.path, SavedConfig.new(directory: directory).find("192.0.2.1")
    end
  end

  def test_equivalent_ipv6_addresses_have_one_canonical_backup
    inventory = inventory(host: "2001:0db8:0000:0000:0000:0000:0000:0001")
    collector = fleet(inventory)
    Dir.mktmpdir do |directory|
      first = collector.backup_all(directory: directory)
      assert first.success?, first.outcomes.inspect
      inventory.devices.first.merge!("ip" => "2001:db8::1", "name" => "renamed")
      second = collector.backup_all(directory: directory)
      assert second.success?, second.outcomes.inspect

      assert_equal :unchanged, second.outcomes.first.backup.change
      assert_equal ["2001_db8__1.txt"], backup_entries(directory, host: "2001:db8::1")
      assert_equal first.outcomes.first.backup.path,
                   SavedConfig.new(directory: directory).find("2001:0db8:0:0:0:0:0:1")
    end
  end

  def test_noncanonical_names_are_not_read_or_used_as_a_change_baseline
    Dir.mktmpdir do |directory|
      other = File.join(directory, "old-name-192.0.2.1.txt")
      File.binwrite(other, CONFIG)
      saved = SavedConfig.new(directory: directory)
      assert_nil saved.find("192.0.2.1", required: false)
      assert_raises(Errno::ENOENT) { saved.read("192.0.2.1") }
      changes = []
      result = fleet(inventory).backup_all(directory: directory, on_change: ->(item) { changes << item.backup.change })
      assert result.success?
      assert_equal :created, result.outcomes.first.backup.change
      assert_nil result.outcomes.first.backup.previous_sha256
      assert_equal [:created], changes
      assert_equal CONFIG, File.binread(other)
      assert_equal CONFIG, saved.read("192.0.2.1")
    end
  end

  def test_only_canonical_files_are_used_even_when_other_names_contain_the_address
    Dir.mktmpdir do |directory|
      %w[first second].each { |name| File.binwrite(File.join(directory, "#{name}-192.0.2.1.txt"), name) }
      canonical = File.join(directory, "192.0.2.1.txt")
      File.binwrite(canonical, CONFIG)
      assert_equal canonical, SavedConfig.new(directory: directory).find("192.0.2.1")

      batch = fleet(inventory).backup_all(directory: directory)
      assert batch.success?, batch.outcomes.inspect
      assert_equal :unchanged, batch.outcomes.first.backup.change
      assert_equal Digest::SHA256.hexdigest(CONFIG), batch.outcomes.first.backup.previous_sha256
      %w[first second].each { |name| assert_equal name, File.binread(File.join(directory, "#{name}-192.0.2.1.txt")) }
    end
  end

  def test_invalid_canonical_file_is_rejected_before_credentials_or_device_io
    [:symlink, :dangling_symlink, :directory].each do |kind|
      Dir.mktmpdir do |directory|
        legacy = File.join(directory, "old-name-192.0.2.1.txt")
        File.binwrite(legacy, "old configuration")
        canonical = File.join(directory, "192.0.2.1.txt")
        case kind
        when :symlink then File.symlink(legacy, canonical)
        when :dangling_symlink then File.symlink(File.join(directory, "missing"), canonical)
        when :directory then Dir.mkdir(canonical)
        end
        error = assert_raises(ArgumentError) { SavedConfig.new(directory: directory).find("192.0.2.1") }
        assert_match(/not a regular file/, error.message)

        calls = []
        batch = fleet(inventory, connector_factory: ->(*) { calls << :connector }).backup_all(directory: directory)
        refute batch.success?, kind
        assert_equal "ArgumentError", batch.outcomes.first.error_type
        assert_empty calls
        assert_equal "old configuration", File.binread(legacy)
        assert_equal(kind == :directory, File.directory?(canonical))
        assert_equal(kind != :directory, File.symlink?(canonical))
      end
    end
  end

  def test_failed_collection_preserves_unrelated_files_and_creates_no_backup
    Dir.mktmpdir do |directory|
      legacy = File.join(directory, "old-name-192.0.2.1.txt")
      File.binwrite(legacy, "old configuration")
      factory = ->(device, settings) { device.build_connector(**settings, transport: ConnectorFake.new("[sw]", :timeout)) }
      batch = fleet(inventory, connector_factory: factory).backup_all(directory: directory)

      refute batch.success?
      assert_equal :failed, batch.outcomes.first.status
      assert_equal "old configuration", File.binread(legacy)
      assert_equal ["old-name-192.0.2.1.txt"], backup_entries(directory)
    end
  end

  def test_cli_exports_canonical_files_without_inventory
    ["192.0.2.1.txt"].each do |filename|
      Dir.mktmpdir do |directory|
        File.binwrite(File.join(directory, filename), CONFIG)
        output = StringIO.new
        error = StringIO.new
        status = Netdisco::CLI.new(argv: ["--directory", directory, "--export", "192.0.2.1"], env: {},
                                   output: output, error: error, fleet_factory: ->(*) { raise "inventory not needed" }).run

        assert_equal 0, status, error.string
        assert_equal CONFIG, output.string
      end
    end
  end
end
