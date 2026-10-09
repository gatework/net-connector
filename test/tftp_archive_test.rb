# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "timeout"
require_relative "../lib/net/connector/netdisco"

class TftpArchiveTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_first_history_run_creates_its_report_directory
    Dir.mktmpdir do |root|
      directory = File.join(root, "new")
      fleet = N::Fleet.new(settings: N::Settings.new(env: {}), result_store: nil,
                           client: Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }]),
                           credentials: ->(*) { nil })
      report = fleet.tftp_backup_all(server: "192.0.2.10", preserve_history: true, report_directory: directory)
      assert_equal [:missing_credentials], report.outcomes.map(&:status)
      assert_equal 1, Dir.glob(File.join(directory, ".tftp-run-*")).size
      assert_equal 0o700, File.stat(directory).mode & 0o777
    end
  end

  def test_archive_write_failures_keep_committed_paths_and_diagnostics_without_reuploading
    writer = Net::Connector::Storage::PrivateFile.method(:write)
    %i[local_path archive_path].product(%i[not_committed committed durable], [false, true]).each do |target, state, already_failed|
      Dir.mktmpdir do |root|
        server = File.join(root, "server")
        FileUtils.mkdir_p(server)
        item = device("H3C")
        archive = N::TftpArchive.new(directory: root, root: server)
        batch_path = File.join(root, "tftp", "edge-192.0.2.1.cfg")
        failed_path = nil
        writes = []
        uploads = 0
        original_diagnostic = N::Diagnostic.new(error_code: :log_error, error_type: "Net::Connector::LogError", phase: :logging)
        failure = lambda do |path, contents|
          writes << path
          matches = target == :local_path ? path == batch_path : path.start_with?(File.join(File.realpath(server), "archive") + "/")
          unless matches
            next writer.call(path, contents)
          end
          failed_path = path
          writer.call(path, contents) unless state == :not_committed
          receipt = Net::Connector::Storage::PrivateFile::Receipt.new(path: path, state: state,
                                                                      phase: { not_committed: :file_sync, committed: :directory_sync, durable: :cleanup }.fetch(state))
          raise Net::Connector::Storage::PrivateFile::PersistenceError.new(receipt: receipt, underlying_type: "Errno::EIO")
        end
        result = Net::Connector::Storage::PrivateFile.stub(:write, failure) do
          archive.upload_and_archive(item, started_at: Time.now.utc) do |remote|
            uploads += 1
            File.write(File.join(server, remote), "configuration")
            uploaded = outcome(item, remote)
            already_failed ? uploaded.with(status: :reported_with_error, error_code: :log_error,
                                           error_type: "Net::Connector::LogError", diagnostic: original_diagnostic) : uploaded
          end
        end
        assert_equal 1, uploads
        assert_equal writes.uniq, writes
        assert_equal :reported_with_error, result.status, "#{target}/#{state}"
        assert_equal :server_verified, result.backup.verification
        if state == :not_committed
          assert_nil result.backup.public_send(target)
        else
          assert_equal failed_path, result.backup.public_send(target)
          assert_equal "configuration", File.read(failed_path)
        end
        assert_equal batch_path, result.backup.local_path if target == :archive_path
        if already_failed
          assert_equal :log_error, result.error_code
          assert_same original_diagnostic, result.diagnostic
        else
          assert_equal state, result.diagnostic.artifact_state
          assert_equal :tftp_archive_failed, result.diagnostic.error_code
          assert_equal "Errno::EIO", result.diagnostic.underlying_type
        end
        assert File.file?(File.join(server, item.tftp_filename))
      end
    end
  end

  def test_builtin_archive_errors_survive_report_serialization
    [N::TftpArchive::ArchiveFailed, N::TftpArchive::Unavailable].each do |type|
      error = type.new(host: "192.0.2.1")
      item = N::Outcome.new(device: device("H3C"), status: :failed, backup: nil,
                            error_code: error.code, error_type: type.name, diagnostic: N::Diagnostic.from(error))
      batch = N::Batch.new(mode: :tftp, outcomes: [item], started_at: Time.now.utc, finished_at: Time.now.utc,
                           callback_errors: [], report_location: nil, report_error: nil)
      entry = batch.build_report.summary.fetch(:devices).first
      assert_equal error.code, entry.fetch(:error_code)
      assert_equal type.name, entry.fetch(:error_type)
    end
  end

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

  def test_unchanged_server_file_is_not_upload_evidence_even_with_a_future_mtime
    Dir.mktmpdir do |root|
      server = File.join(root, "server")
      FileUtils.mkdir_p(server)
      item = device("Palo Alto Networks")
      path = File.join(server, item.tftp_filename)
      File.write(path, "previous device configuration")
      future = Time.now + 60
      File.utime(future, future, path)
      archive = N::TftpArchive.new(directory: root, root: server)

      result = archive.upload_and_archive(item, started_at: Time.now.utc - 1) { |remote| outcome(item, remote) }

      assert_equal :reported_with_error, result.status
      assert_equal :device_reported, result.backup.verification
      assert_nil result.backup.local_path
      assert_equal "previous device configuration", File.read(path)
    end
  end

  def test_rewriting_the_same_contents_in_a_precreated_server_file_is_a_new_upload
    Dir.mktmpdir do |root|
      server = File.join(root, "server")
      FileUtils.mkdir_p(server)
      item = device("Palo Alto Networks")
      path = File.join(server, item.tftp_filename)
      File.write(path, "same configuration")
      previous = Time.now - 60
      File.utime(previous, previous, path)
      inode = File.stat(path).ino
      archive = N::TftpArchive.new(directory: root, root: server)

      result = archive.upload_and_archive(item, started_at: Time.now.utc - 1) do |remote|
        assert_equal inode, File.stat(path).ino, "precreated upload targets must remain available to the server"
        File.write(path, "same configuration")
        outcome(item, remote)
      end

      assert_equal :reported_uploaded, result.status
      assert_equal :server_verified, result.backup.verification
      assert_equal "same configuration", File.read(result.backup.archive_path)
    end
  end

  def test_queued_fixed_name_upload_cannot_archive_the_previous_partial_upload_as_its_own
    Dir.mktmpdir do |root|
      server = File.join(root, "server")
      FileUtils.mkdir_p(server)
      first = device("Palo Alto Networks")
      second = N::Device.from_row({ "ip" => "192.0.2.2", "name" => "other", "vendor" => "Palo Alto Networks" }, rules: N::Rules.new)
      archive = N::TftpArchive.new(directory: root, root: server)
      entered, release, waiting = Queue.new, Queue.new, Queue.new
      synchronize = Net::Connector::Storage::BackupLock.method(:synchronize)
      observe_waiter = lambda do |path, **options, &block|
        waiting << true if options[:host] == second.host
        synchronize.call(path, **options, &block)
      end
      Net::Connector::Storage::BackupLock.stub(:synchronize, observe_waiter) do
        first_thread = second_thread = nil
        Timeout.timeout(5) do
          first_thread = Thread.new do
            archive.upload_and_archive(first, started_at: Time.now.utc) do |remote|
              entered << true
              release.pop
              File.write(File.join(server, remote), "first device configuration")
              outcome(first, remote).with(status: :reported_with_error, error_code: :log_error)
            end
          end
          entered.pop
          second_started = Time.now.utc
          second_thread = Thread.new do
            archive.upload_and_archive(second, started_at: second_started) { |remote| outcome(second, remote) }
          end
          waiting.pop
          release << true
          first_result, second_result = first_thread.value, second_thread.value
          assert_equal :server_verified, first_result.backup.verification
          assert_equal "first device configuration", File.read(first_result.backup.local_path)
          assert_equal :reported_with_error, second_result.status
          assert_equal :device_reported, second_result.backup.verification
          assert_nil second_result.backup.local_path
          refute File.exist?(File.join(root, "tftp", "other-192.0.2.2.xml"))
        end
      ensure
        [first_thread, second_thread].compact.each { |thread| thread.kill.join if thread.alive? }
      end
    end
  end

  def test_upload_freshness_uses_the_filesystem_clock_when_wall_time_is_ahead
    Dir.mktmpdir do |root|
      server = File.join(root, "server")
      FileUtils.mkdir_p(server)
      item = device("Palo Alto Networks")
      archive = N::TftpArchive.new(directory: root, root: server)
      wall_time = Time.now + 60

      result = Time.stub(:now, wall_time) do
        archive.upload_and_archive(item, started_at: wall_time) do |remote|
          path = File.join(server, remote)
          File.write(path, "new configuration")
          assert_operator File.mtime(path), :<, wall_time
          outcome(item, remote)
        end
      end

      assert_equal :reported_uploaded, result.status
      assert_equal :server_verified, result.backup.verification
      assert_equal "new configuration", File.read(result.backup.archive_path)
      assert_empty Dir.glob(File.join(server, ".net-connector-upload-*"))
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

  def test_upload_without_a_local_root_returns_the_device_receipt
    Dir.mktmpdir do |directory|
      archive = N::TftpArchive.new(directory: directory)
      item = device("H3C")
      result = archive.upload_and_archive(item, started_at: Time.now.utc) { |remote| outcome(item, remote) }
      assert_equal archive.upload_filename(item), result.backup.path
      assert_equal :device_reported, result.backup.verification
    end
  end
end
