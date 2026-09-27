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

  def fleet(client, config: CONFIG, **options)
    Netdisco::Fleet.new(client: client, settings: Netdisco::Settings.new(env: {}), result_store: nil,
                        credentials: ->(_) { { username: "backup" } },
                        connector_factory: ->(device, settings) {
                          device.build_connector(**settings, transport: ConnectorFake.new("[sw]", config))
                        }, **options)
  end

  def client(name: "new-name", host: "192.0.2.1")
    Struct.new(:devices).new([{ "ip" => host, "vendor" => "H3C", "name" => name }])
  end

  # 新增的持久路径锁是文件协议的一部分；仅排除当前目标的这一项，其他多余文件仍会失败。
  def backup_entries(directory, host: "192.0.2.1")
    path = File.join(directory, SavedConfig.filename(host))
    Dir.children(directory) - [File.basename(Net::Connector::Storage::BackupLock.lock_path(path))]
  end

  def test_renaming_inventory_keeps_one_backup_and_its_change_baseline
    inventory = client(name: "old-name")
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
    inventory = client(host: "2001:0db8:0000:0000:0000:0000:0000:0001")
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
      result = fleet(client).backup_all(directory: directory, on_change: ->(item) { changes << item.backup.change })
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

      batch = fleet(client).backup_all(directory: directory)
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
        batch = fleet(client, connector_factory: ->(*) { calls << :connector }).backup_all(directory: directory)
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
      batch = fleet(client, connector_factory: factory).backup_all(directory: directory)

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
