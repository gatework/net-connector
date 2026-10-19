# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../lib/net/connector/netdisco"
require_relative "../lib/net/connector/netdisco/ssh/archive/client"
require_relative "support/fake_transport"

class SshArchiveClientTest < Minitest::Test
  N = Net::Connector::Netdisco
  WORKER = File.expand_path("../lib/net/connector/netdisco/ssh/archive/worker.py", __dir__)

  def test_remote_roots_keep_their_uri_without_copying_credentials
    settings = N::Settings.new(env: {}, defaults: N::Config.parse("tftp" => {
      "server" => "192.0.2.10", "verification_roots" => { "192.0.2.10" => "ssh://archive@backup.example/srv/tftp" }
    }))
    assert_equal "ssh://archive@backup.example/srv/tftp", settings.tftp_policy.for(host: "192.0.2.1", vendor: :palo_alto).verification_root
    assert_equal settings.tftp_verification_roots, settings.snapshot(mode: :tftp).tftp_verification_roots
    ["ssh://root:private@host/srv/tftp", "ssh://root@host/srv/../tftp", "ssh://root@host/srv/tftp?cmd=x",
     "ssh://-option@-host/srv/tftp", "ssh://root@host/srv/%00tftp"].each do |root|
      assert_raises(ArgumentError) { N::Tftp::Root.endpoint(root) }
    end
  end

  def test_old_file_and_new_upload_are_retained_before_staging_cleanup
    with_archive do |archive, server, reports|
      File.write(File.join(server, "running-config.xml"), "previous")
      item = device
      outcome = archive.upload_and_archive(item, started_at: Time.now.utc) do |name|
        assert_equal "running-config.xml", name
        assert_equal(["previous"], Dir[File.join(server, "archive/*/previous/*")].map { |p| File.read(p) })
        File.write(File.join(server, name), "new configuration")
        uploaded(item, name)
      end
      assert_equal :reported_uploaded, outcome.status
      assert_equal :server_verified, outcome.backup.verification
      assert_equal Digest::SHA256.hexdigest("new configuration"), outcome.backup.server_sha256
      assert_equal "new configuration", File.read(outcome.backup.local_path)
      assert outcome.backup.local_path.start_with?(reports)
      assert_match %r{\Assh://archive@backup.example/}, outcome.backup.archive_path
      assert_equal(["new configuration"], Dir[File.join(server, "archive/*/edge-*.xml")].map { |p| File.read(p) })
      refute File.exist?(File.join(server, "running-config.xml"))
    end
  end

  def test_unchanged_file_is_never_verified_or_reuploaded
    with_archive do |archive, server, _|
      File.write(File.join(server, "running-config.xml"), "old")
      calls = 0
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        calls += 1
        uploaded(device, name)
      end
      assert_equal 1, calls
      assert_equal :reported_with_error, result.status
      assert_equal :device_reported, result.backup.verification
      assert_equal "old", File.read(File.join(server, "running-config.xml"))
    end
  end

  def test_shared_staging_root_keeps_private_archive_and_lock_directories
    with_archive do |archive, server, _|
      File.chmod(0o777, server)
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        File.write(File.join(server, name), "uploaded")
        uploaded(device, name)
      end
      assert result.success?
      %w[archive .net-connector-locks].each do |name|
        assert_equal 0o700, File.stat(File.join(server, name)).mode & 0o7777
      end
    end
  end

  def test_prepare_rejects_shared_metadata_before_any_upload
    with_archive do |archive, server, _|
      path = File.join(server, "archive")
      Dir.mkdir(path, 0o755)
      File.chmod(0o755, path)
      error = assert_raises(ArgumentError) { archive.prepare }
      assert_includes error.message, "0700"
      assert_equal 0o755, File.stat(path).mode & 0o7777
      assert_empty Dir[File.join(server, "*.cfg")]
    end
  end

  def test_prepare_checks_remote_directories_without_leaving_upload_files
    with_archive do |archive, server, _|
      archive.prepare
      assert_equal 0o700, File.stat(File.join(server, "archive")).mode & 0o7777
      assert_equal 0o700, File.stat(File.join(server, ".net-connector-locks")).mode & 0o7777
      assert_empty Dir[File.join(server, "*.cfg")]
      assert_empty Dir[File.join(server, ".net-connector-upload-*")]
    end
  end

  def test_existing_shared_metadata_directories_are_rejected_without_chmod
    %w[archive .net-connector-locks].each do |name|
      with_archive do |archive, server, _|
        path = File.join(server, name)
        Dir.mkdir(path, 0o700)
        File.chmod(0o777, path)
        assert_raises(N::Tftp::Archive::Failure) do
          archive.upload_and_archive(device, started_at: Time.now.utc) { flunk "unsafe metadata permitted upload" }
        end
        assert_equal 0o777, File.stat(path).mode & 0o7777
      end
    end
  end

  def test_archive_directory_replacement_does_not_follow_a_new_symlink
    with_archive do |archive, server, reports|
      outside = File.join(reports, "outside")
      Dir.mkdir(outside)
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        batch = Dir[File.join(server, "archive/*")].fetch(0)
        File.rename(batch, batch + "-retained")
        File.symlink(outside, batch)
        File.write(File.join(server, name), "uploaded")
        uploaded(device, name)
      end
      assert_equal :reported_with_error, result.status
      assert_empty Dir.children(outside)
      assert_equal "uploaded", File.read(File.join(server, "running-config.xml"))
    end
  end

  def test_replaced_lock_inode_prevents_archival_and_staging_cleanup
    with_archive do |archive, server, _|
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        lock = Dir[File.join(server, ".net-connector-locks/*")].fetch(0)
        File.unlink(lock)
        File.open(lock, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("replacement") }
        File.write(File.join(server, name), "uploaded")
        uploaded(device, name)
      end
      assert_equal :reported_with_error, result.status
      assert_equal "uploaded", File.read(File.join(server, "running-config.xml"))
      assert_empty Dir[File.join(server, "archive/*/*.xml")]
    end
  end

  def test_existing_lock_must_be_private_regular_and_have_one_link
    %i[shared hardlinked symlink].each do |kind|
      with_archive do |archive, server, reports|
        lock_directory = File.join(server, ".net-connector-locks")
        Dir.mkdir(lock_directory, 0o700)
        lock = File.join(lock_directory, Digest::SHA256.hexdigest("running-config.xml"))
        target = File.join(reports, "lock-target")
        File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("untouched") }
        case kind
        when :shared
          File.open(lock, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
          File.chmod(0o644, lock)
        when :hardlinked then File.link(target, lock)
        when :symlink then File.symlink(target, lock)
        end
        assert_raises(N::Tftp::Archive::Failure) do
          archive.upload_and_archive(device, started_at: Time.now.utc) { flunk "unsafe lock permitted upload" }
        end
        assert_equal "untouched", File.read(target)
      end
    end
  end

  def test_replacement_between_boundary_check_and_write_stays_in_the_pinned_directory
    Dir.mktmpdir do |directory|
      server, reports, outside = %w[server reports outside].map { |name| File.join(File.realpath(directory), name) }
      FileUtils.mkdir_p([server, reports, outside])
      # Replace the parent immediately before persist, after transaction validation.
      harness = <<~PYTHON
        import importlib.util, os, sys
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location("worker", sys.argv[1])
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        original = worker.persist
        def replaced(*args):
            parent = os.path.join(sys.argv[2], "archive")
            batch = os.path.join(parent, os.listdir(parent)[0])
            os.rename(batch, batch + "-retained")
            os.symlink(sys.argv[3], batch)
            return original(*args)
        worker.persist = replaced
        try:
            worker.run()
        except Exception:
            print('{"ok": false, "error": "tftp_archive_failed"}', flush=True)
      PYTHON
      launcher = ->(&block) { Open3.popen3("python3", "-u", "-c", harness, WORKER, server, outside, &block) }
      archive = N::SSH::Archive::Client.new(directory: reports, root: "ssh://archive@backup.example#{server}", launcher: launcher)
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        File.write(File.join(server, name), "uploaded")
        uploaded(device, name)
      end
      assert_equal :reported_with_error, result.status
      assert_empty Dir.children(outside)
      assert_equal(["uploaded"], Dir[File.join(server, "archive/*-retained/*.xml")].map { |path| File.read(path) })
      assert_equal "uploaded", File.read(File.join(server, "running-config.xml"))
    ensure
      archive&.close
    end
  end

  def test_remote_symlink_rejects_upload_before_device_io
    with_archive do |archive, server, reports|
      target = File.join(reports, "outside")
      File.write(target, "untouched")
      File.symlink(target, File.join(server, "running-config.xml"))
      assert_raises(N::Tftp::Archive::Failure) do
        archive.upload_and_archive(device, started_at: Time.now.utc) { flunk "device upload must not run" }
      end
      assert_equal "untouched", File.read(target)
    end
  end

  def test_a_failed_ssh_authentication_is_not_retried_for_each_device
    Dir.mktmpdir do |directory|
      archive = N::SSH::Archive::Client.new(directory: directory, root: "ssh://archive@backup.example/srv/tftp")
      attempts = 0
      archive.stub(:system, lambda { |*args, **options|
        attempts += 1
        assert_includes args, "BatchMode=yes"
        assert_equal File::NULL, options[:in]
        assert_equal File::NULL, options[:err]
        false
      }) do
        2.times do
          error = assert_raises(N::SSH::Archive::Client::AuthenticationUnavailable) { archive.prepare }
          assert_includes error.message, "NC_TFTP_SSH_PASSWORD"
        end
      end
      assert_equal 1, attempts
    ensure
      archive&.close
    end
  end

  def test_local_archive_failure_preserves_server_copy_without_reupload
    with_archive do |archive, server, _|
      calls = 0
      result = Net::Connector::Storage::AtomicFile.stub(:write, ->(*) { raise IOError, "disk full" }) do
        archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
          calls += 1
          File.write(File.join(server, name), "uploaded")
          uploaded(device, name)
        end
      end
      assert_equal 1, calls
      assert_equal :reported_with_error, result.status
      assert_equal :server_verified, result.backup.verification
      assert result.backup.archive_path
      assert_equal "uploaded", File.read(File.join(server, "running-config.xml"))
      assert_equal(["uploaded"], Dir[File.join(server, "archive/*/edge-*.xml")].map { |p| File.read(p) })
    end
  end

  def test_two_fixed_name_uploads_are_serialized_by_the_server_lock
    with_archive do |archive, server, _|
      events = Queue.new
      threads = %w[192.0.2.1 192.0.2.2].map do |host|
        Thread.new do
          item = device(host)
          archive.upload_and_archive(item, started_at: Time.now.utc) do |name|
            events << [host, :start]
            File.write(File.join(server, name), host)
            Thread.pass
            events << [host, :end]
            uploaded(item, name)
          end
        end
      end
      results = threads.map(&:value)
      assert results.all?(&:success?)
      observed = 4.times.map { events.pop }
      assert_equal observed[0][0], observed[1][0]
      assert_equal observed[2][0], observed[3][0]
      assert_equal %w[192.0.2.1 192.0.2.2], results.map { |r| File.read(r.backup.local_path) }.sort
    end
  end

  def test_fleet_plans_and_verifies_every_fixed_name_device_with_an_ssh_root
    with_archive do |_archive, server, reports|
      hosts = %w[192.0.2.1 192.0.2.2 192.0.2.3]
      rows = hosts.map { |host| { "ip" => host, "vendor" => "Palo Alto Networks", "name" => "edge" } }
      fleet = N::Fleet.new(settings: N::Settings.new(env: {}), report_store: nil, inventory: Struct.new(:devices).new(rows),
                           credentials: ->(*) { { username: "audit" } }, connector_factory: lambda { |item, options|
        transport = ConnectorFake.new("admin@fw>", "Sent 128 bytes in 1.0 seconds [1024 bit/s]\nadmin@fw>")
        transport.on_write = ->(*) { File.write(File.join(server, "running-config.xml"), "configuration #{item.host}") }
        item.build_connector(**options, transport: transport)
      })
      original = N::SSH::Archive::Client.method(:new)
      factory = lambda do |directory:, root:, password: nil|
        original.call(directory: directory, root: root, password: password,
                      launcher: ->(&block) { Open3.popen3("python3", "-u", WORKER, &block) })
      end
      report = N::SSH::Archive::Client.stub(:new, factory) do
        fleet.tftp_backup_all(server: "192.0.2.10", verification_root: "ssh://archive@backup.example#{server}",
                              preserve_history: true, report_directory: reports, success_policy: :verified, parallel: 3)
      end
      assert report.policy_success?
      assert_equal hosts, report.outcomes.map { |o| o.device.host }.sort
      assert(report.outcomes.all? { |o| o.backup.verification == :server_verified })
      assert_equal 3, Dir[File.join(reports, "tftp/*.xml")].size
      assert_equal 3, Dir[File.join(server, "archive/*/*.xml")].size
      refute File.exist?(File.join(server, "running-config.xml"))
      plan = N::Planner.new(report.outcomes.map(&:device)).call(mode: :tftp, limit_per_vendor: nil, allow_fixed_name_reuse: true)
      N::Report::Text.write(directory: reports, report: report, plan: plan, parallel: 3)
      assert_includes File.read(File.join(reports, "summary.txt")), "TFTP 服务器文件：已核验 3，未核验 0。"
    end
  end

  private

  def device(host = "192.0.2.1")
    N::Device.from_row({ "ip" => host, "name" => "edge", "vendor" => "Palo Alto Networks" }, rules: N::Rules.new)
  end

  def uploaded(item, path)
    receipt = Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: path, completed_at: Time.now.utc)
    N::Outcome.new(device: item, status: :reported_uploaded, backup: receipt, error_code: nil, error_type: nil)
  end

  def with_archive
    Dir.mktmpdir do |root|
      server = File.join(File.realpath(root), "server")
      reports = File.join(File.realpath(root), "reports")
      FileUtils.mkdir_p([server, reports])
      launcher = ->(&block) { Open3.popen3("python3", "-u", WORKER, &block) }
      archive = N::SSH::Archive::Client.new(directory: reports, root: "ssh://archive@backup.example#{server}", launcher: launcher)
      yield archive, server, reports
    ensure
      archive&.close
    end
  end
end
