# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "digest"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class LegacyIndexTest < Minitest::Test
  SavedConfig = Net::Connector::Operations::SavedConfig
  SafeFile = Net::Connector::Operations::SafeFile
  CONFIG = "sysname sw\ninterface GigabitEthernet1/0/1\n#\n[sw]"
  HOST = "192.0.2.1"

  def test_concurrent_batch_scans_legacy_directory_once_and_keeps_unchanged_baselines
    Dir.mktmpdir do |directory|
      hosts = (1..8).map { |index| "192.0.2.#{index}" }
      hosts.each { |host| File.binwrite(File.join(directory, "old-#{host}.txt"), CONFIG) }
      collector = fleet(hosts)
      count_scans(directory) do |count|
        batch = collector.backup_all(directory: directory, concurrency: 4)
        assert batch.success?, batch.outcomes.inspect
        assert_equal [:unchanged], batch.outcomes.map { |outcome| outcome.backup.change }.uniq
        assert_equal [Digest::SHA256.hexdigest(CONFIG)], batch.outcomes.map { |outcome| outcome.backup.previous_sha256 }.uniq
        assert_equal 1, count.call
      end
      # 同一 Fleet 的新批次重新扫描；旧索引不能藏起新增的歧义候选。
      hosts.each { |host| File.unlink(File.join(directory, SavedConfig.filename(host))) }
      File.binwrite(File.join(directory, "another-#{HOST}.txt"), CONFIG)
      count_scans(directory) do |count|
        batch = collector.backup_all(directory: directory, concurrency: 4)
        refute batch.success?
        assert_equal :failed, batch.outcomes.find { |outcome| outcome.device.host == HOST }.status
        assert_equal 1, count.call
      end
    end
  end

  def test_canonical_only_batch_performs_no_directory_scan
    Dir.mktmpdir do |directory|
      hosts = (1..8).map { |index| "192.0.2.#{index}" }
      hosts.each { |host| File.binwrite(File.join(directory, SavedConfig.filename(host)), CONFIG) }
      count_scans(directory) do |count|
        batch = fleet(hosts).backup_all(directory: directory, concurrency: 4)
        assert batch.success?, batch.outcomes.inspect
        assert_equal 0, count.call
      end
    end
  end

  def test_changed_baseline_fails_before_that_devices_credentials_or_connection
    Dir.mktmpdir do |directory|
      hosts = [HOST, "192.0.2.2"]
      hosts.each { |host| File.binwrite(File.join(directory, "old-#{host}.txt"), CONFIG) }
      calls = []
      credentials = lambda do |device|
        calls << device.host
        File.binwrite(File.join(directory, "old-192.0.2.2.txt"), "changed after snapshot")
        { username: "backup" }
      end
      batch = fleet(hosts, credentials: credentials).backup_all(directory: directory, concurrency: 1, report_schema: 2)
      refute batch.success?
      assert_equal [HOST], calls
      failed = batch.outcomes.find { |outcome| outcome.device.host == "192.0.2.2" }
      assert_equal :failed, failed.status
      assert_equal :saved_config_changed, failed.error_code
      assert_nil failed.backup
      refute File.exist?(File.join(directory, "192.0.2.2.txt"))
      diagnostic = batch.summary.fetch(:devices).find { |entry| entry[:host] == "192.0.2.2" }
      assert_equal "Net::Connector::SavedConfigChanged", diagnostic.fetch(:error_type)
      assert_equal :saved_config_changed, diagnostic.fetch(:error_code)
      assert_equal :backup, diagnostic.fetch(:diagnostic).fetch(:phase)
    end
  end

  def test_index_is_a_batch_snapshot_but_canonical_files_always_win
    Dir.mktmpdir do |directory|
      indexed = SavedConfig.new(directory: directory, indexed: true)
      live = SavedConfig.new(directory: directory)
      assert_nil indexed.find(HOST, required: false)
      assert_nil live.find(HOST, required: false)
      legacy = File.join(directory, "old-#{HOST}.txt")
      File.binwrite(legacy, "legacy")
      assert_nil indexed.find(HOST, required: false)
      assert_equal legacy, live.find(HOST)
      assert_equal "legacy", SavedConfig.new(directory: directory, indexed: true).read(HOST)
      canonical = File.join(directory, SavedConfig.filename(HOST))
      File.binwrite(canonical, "canonical")
      assert_equal "canonical", indexed.read(HOST)
    end
  end

  def test_ipv6_legacy_suffixes_are_normalized_including_scoped_addresses
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "old-2001_0DB8_0000_0000_0000_0000_0000_0001.txt"), "ipv6")
      File.binwrite(File.join(directory, "old-fe80__1%zone_a.txt"), "scoped")
      saved = SavedConfig.new(directory: directory, indexed: true)
      assert_equal "ipv6", saved.read("2001:db8::1")
      assert_equal "scoped", saved.read("fe80::1%zone_a")
      File.binwrite(File.join(directory, "other-2001_db8__1.txt"), "other")
      error = assert_raises(ArgumentError) { SavedConfig.new(directory: directory, indexed: true).read("2001:db8::1") }
      assert_match(/multiple saved configurations/, error.message)
    end
  end

  def test_unsafe_legacy_types_are_rejected_without_affecting_other_hosts
    %i[symlink dangling_symlink directory fifo].each do |kind|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "old-#{HOST}.txt")
        other = File.join(directory, "valid-192.0.2.2.txt")
        File.binwrite(other, "safe")
        case kind
        when :symlink then File.symlink(other, path)
        when :dangling_symlink then File.symlink(File.join(directory, "missing"), path)
        when :directory then Dir.mkdir(path)
        when :fifo then File.mkfifo(path)
        end
        saved = SavedConfig.new(directory: directory, indexed: true)
        assert_equal "safe", saved.read("192.0.2.2")
        assert_raises(ArgumentError) { saved.read(HOST) }
      end
    end
  end

  def test_changed_removed_or_replaced_snapshot_entry_cannot_supply_a_baseline
    %i[removed replaced overwritten symlink].each do |kind|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "old-#{HOST}.txt")
        File.binwrite(path, "original")
        saved = SavedConfig.new(directory: directory, indexed: true)
        assert_equal path, saved.find(HOST)
        case kind
        when :removed then File.unlink(path)
        when :overwritten then File.binwrite(path, "changed and longer")
        when :replaced
          File.binwrite("#{path}.new", "original")
          File.rename("#{path}.new", path)
        when :symlink
          File.unlink(path)
          File.symlink("missing", path)
        end
        error = assert_raises(Net::Connector::SavedConfigChanged) { saved.fingerprint(HOST) }
        assert_equal :saved_config_changed, error.code
        assert_nil error.cause
        assert_empty error.output
      end
    end
  end

  def test_read_checks_both_the_open_descriptor_and_directory_entry_after_consumption
    %i[replace overwrite].each do |kind|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "old-#{HOST}.txt")
        File.binwrite(path, "original")
        saved = SavedConfig.new(directory: directory, indexed: true)
        saved.find(HOST)
        open_file = SafeFile.method(:open)
        intercept = lambda do |target, **options, &block|
          open_file.call(target, **options) do |file, stat|
            file.define_singleton_method(:read) do |*arguments|
              bytes = super(*arguments)
              if kind == :replace
                File.binwrite("#{path}.new", "replacement")
                File.rename("#{path}.new", path)
              else
                File.binwrite(path, "longer in-place change")
              end
              bytes
            end
            block.call(file, stat)
          end
        end
        SafeFile.stub(:open, intercept) do
          assert_raises(Net::Connector::SavedConfigChanged) { saved.read(HOST) }
        end
      end
    end
  end

  def test_failed_snapshot_is_not_partially_published_or_retried_by_each_worker
    Dir.mktmpdir do |directory|
      saved = SavedConfig.new(directory: directory, indexed: true)
      scans = 0
      Dir.stub(:children, ->(*) { scans += 1; raise Errno::EACCES }) do
        2.times do
          error = assert_raises(IOError) { saved.find(HOST, required: false) }
          assert_nil error.cause
        end
      end
      assert_equal 1, scans
      File.binwrite(File.join(directory, "old-#{HOST}.txt"), "new batch")
      assert_equal "new batch", SavedConfig.new(directory: directory, indexed: true).read(HOST)
    end
  end

  def test_entry_missing_between_listing_and_stat_cannot_accept_a_later_replacement
    Dir.mktmpdir do |directory|
      path = File.join(directory, "old-#{HOST}.txt")
      File.binwrite(path, "original")
      saved = SavedConfig.new(directory: directory, indexed: true)
      lstat = File.method(:lstat)
      first = true
      intercept = lambda do |target|
        if target == path && first
          first = false
          File.unlink(path)
          File.binwrite(path, "replacement")
          raise Errno::ENOENT
        end
        lstat.call(target)
      end
      File.stub(:lstat, intercept) do
        assert_raises(Net::Connector::SavedConfigChanged) { saved.read(HOST) }
      end
      assert_equal "replacement", File.binread(path)
    end
  end

  private

  def fleet(hosts, **options)
    client = Struct.new(:devices).new(hosts.map { |host| { "ip" => host, "vendor" => "H3C" } })
    Net::Connector::Netdisco::Fleet.new(client: client, settings: Net::Connector::Netdisco::Settings.new(env: {}), result_store: nil,
                                       credentials: ->(_) { { username: "backup" } },
                                       connector_factory: ->(device, options) {
                                         device.connector(**options, transport: ConnectorFake.new("[sw]", CONFIG))
                                       }, **options)
  end

  def count_scans(directory)
    children = Dir.method(:children)
    count = 0
    mutex = Mutex.new
    counted = lambda do |path, **options|
      mutex.synchronize { count += 1 } if File.expand_path(path) == directory
      children.call(path, **options)
    end
    Dir.stub(:children, counted) { yield -> { mutex.synchronize { count } } }
  end
end
