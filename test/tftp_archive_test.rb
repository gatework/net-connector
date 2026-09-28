# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/net/connector/netdisco"

class TftpArchiveTest < Minitest::Test
  N = Net::Connector::Netdisco

  def device(vendor)
    N::Device.from_row({ "ip" => "192.0.2.1", "name" => "edge", "vendor" => vendor }, rules: N::Rules.new)
  end

  def outcome(device, remote)
    receipt = Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: remote, completed_at: Time.now.utc)
    N::Outcome.new(device: device, status: :reported_uploaded, backup: receipt, error_code: nil, error_type: nil)
  end

  def test_distinct_remote_names_and_fixed_name_archives_survive_later_uploads
    Dir.mktmpdir do |root|
      batches = File.join(root, "batches")
      server = File.join(root, "server")
      FileUtils.mkdir_p([batches, server])
      pan = device("Palo Alto Networks")
      h3c = device("H3C")
      archives = []
      remote_names = []
      server_archives = []
      2.times do |number|
        directory = Net::Connector::Storage::BatchDirectory.create(
          batches, time: Time.new(2026, 9, 28, 15, 30, 0, "+08:00")
        )
        archive = N::TftpArchive.new(directory: directory, root: server)
        remote_names << archive.upload_filename(h3c)
        assert_equal "running-config.xml", archive.upload_filename(pan)
        started = Time.now.utc - 1
        result = archive.upload_and_archive(pan, started_at: started) do |remote|
          File.write(File.join(server, remote), "configuration-#{number}")
          outcome(pan, remote)
        end
        assert_equal :reported_uploaded, result.status
        assert_equal :server_verified, result.backup.verification
        assert_equal "configuration-#{number}", File.read(result.backup.local_path)
        assert_equal 0o600, File.stat(result.backup.local_path).mode & 0o777
        assert_equal "configuration-#{number}", File.read(result.backup.archive_path)
        refute File.exist?(File.join(server, "running-config.xml")), "the TFTP root should only stage uploads"
        assert_equal File.basename(directory), File.basename(File.dirname(result.backup.archive_path))
        assert_match(%r{/archive/\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d{2})?/edge-192\.0\.2\.1\.xml\z},
                     result.backup.archive_path)
        archives << result.backup.local_path
        server_archives << result.backup.archive_path
      end
      assert_equal ["edge-192.0.2.1.cfg"] * 2, remote_names
      refute_equal(*server_archives)
      assert_equal %w[configuration-0 configuration-1], (archives.map { |path| File.read(path) })
      refute File.exist?(File.join(File.dirname(server_archives.last), "previous", "edge-192.0.2.1.xml"))
    end
  end

  def test_existing_server_file_is_preserved_before_upload_and_root_is_cleared_after_archiving
    Dir.mktmpdir do |root|
      server = File.join(root, "server")
      FileUtils.mkdir_p(server)
      item = device("H3C")
      directory = Net::Connector::Storage::BatchDirectory.create(root)
      filename = item.tftp_filename
      File.write(File.join(server, filename), "older configuration")
      archive = N::TftpArchive.new(directory: directory, root: server)

      result = archive.upload_and_archive(item, started_at: Time.now.utc - 1) do |remote|
        File.write(File.join(server, remote), "new configuration")
        outcome(item, remote)
      end

      assert_equal :reported_uploaded, result.status
      assert_equal filename, result.backup.path
      assert_equal "new configuration", File.read(result.backup.local_path)
      assert_equal "new configuration", File.read(result.backup.archive_path)
      assert_equal "older configuration", File.read(File.join(File.dirname(result.backup.archive_path), "previous", filename))
      refute File.exist?(File.join(server, filename))
    end
  end

  def test_missing_server_root_never_overwrites_fixed_name_backup
    Dir.mktmpdir do |root|
      directory = File.join(root, "2026-09-28_15-30-00")
      FileUtils.mkdir_p(directory)
      archive = N::TftpArchive.new(directory: directory)
      first = archive.upload_filename(device("H3C"))
      second = N::TftpArchive.new(directory: directory).upload_filename(device("H3C"))
      assert_equal "edge-192.0.2.1-2026-09-28_15-30-00.cfg", first
      assert_equal "edge-192.0.2.1-2026-09-28_15-30-00_01.cfg", second
      assert_raises(N::TftpArchive::Unavailable) do
        archive.upload_and_archive(device("Palo Alto Networks"), started_at: Time.now.utc) { flunk "must not upload" }
      end
    end
  end

  def test_missing_or_old_server_file_is_not_reported_as_preserved
    Dir.mktmpdir do |directory|
      server = File.join(directory, "server")
      FileUtils.mkdir_p(server)
      item = device("H3C")
      archive = N::TftpArchive.new(directory: directory, root: server)
      result = archive.upload_and_archive(item, started_at: Time.now.utc) { |remote| outcome(item, remote) }
      assert_equal :reported_with_error, result.status
      assert_equal :tftp_archive_failed, result.error_code
      assert_nil result.backup.local_path
    end
  end

  def test_fixed_name_devices_are_all_planned_only_with_archival_permission
    rows = %w[192.0.2.1 192.0.2.2].map do |ip|
      N::Device.from_row({ "ip" => ip, "vendor" => "Palo Alto Networks" }, rules: N::Rules.new)
    end
    planner = N::Planner.new(rows)
    ordinary = planner.call(mode: :tftp, limit_per_vendor: nil)
    assert_equal 1, ordinary.ready.size
    assert_equal :remote_filename_collision, ordinary.outcomes.last.status
    archived = planner.call(mode: :tftp, limit_per_vendor: nil, allow_fixed_name_reuse: true)
    assert_equal 2, archived.validate!.ready.size
  end

  def test_previous_entry_point_keeps_its_constructor_and_method_names
    Dir.mktmpdir do |directory|
      history = N::TftpHistory.new(server: "192.0.2.10", directory: directory)
      item = device("H3C")
      assert_kind_of N::TftpArchive, history
      assert_equal history.upload_filename(item), history.path_for(item)
      result = history.capture(item, started_at: Time.now.utc) { |remote| outcome(item, remote) }
      assert_equal history.path_for(item), result.backup.path
    end
  end
end
