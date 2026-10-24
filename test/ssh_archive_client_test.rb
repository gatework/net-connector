# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "open3"
require "tmpdir"
require "fileutils"
require "weakref"
require_relative "../lib/net/connector/netdisco"
require_relative "../lib/net/connector/netdisco/ssh/archive/client"
require_relative "support/fake_transport"

class SshArchiveClientTest < Minitest::Test
  N = Net::Connector::Netdisco
  WORKER = File.expand_path("../lib/net/connector/netdisco/ssh/archive/worker.py", __dir__)

  def test_closed_clients_and_their_credentials_can_be_collected
    Dir.mktmpdir do |directory|
      references = Thread.new { 20.times.map { closed_client_reference(directory) } }.value
      GC.start(full_mark: true, immediate_sweep: true)
      assert references.none?(&:weakref_alive?), "exit cleanup retained closed clients"
    end
  end

  def test_master_lifetime_is_owned_by_close_for_password_and_key_authentication
    Dir.mktmpdir do |directory|
      [nil, "private-fixture"].each do |password|
        archive = N::SSH::Archive::Client.new(directory: directory, root: "ssh://archive@backup.example/srv/tftp", password: password)
        arguments = []
        archive.stub(:system, ->(*args, **) { arguments << args; true }) do
          N::SSH::Authentication.stub(:respond, ->(args, **) { arguments << args; true }) do
            archive.stub(:prepare_archive, nil) { archive.prepare }
          end
        end
        master = arguments.find { |args| args.include?("-M") }
        assert_includes master, "ControlPersist=yes"
      ensure
        archive&.close
      end
    end
  end

  def test_process_exit_closes_a_still_owned_master
    Dir.mktmpdir do |directory|
      script = <<~'RUBY'
        require "net/connector/netdisco/ssh/archive/client"
        archive = Net::Connector::Netdisco::SSH::Archive::Client.new(directory: ARGV.fetch(0), root: "ssh://archive@backup.example/srv/tftp")
        archive.define_singleton_method(:authenticate_master) { true }
        archive.send(:prepare_master)
        puts archive.instance_variable_get(:@master_directory)
      RUBY
      output, error, status = Open3.capture3(Gem.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, directory)
      assert status.success?, error
      path = output.strip
      assert_match %r{\A/tmp/nc-tftp-[^/\n]+\z}, path
      refute File.exist?(path), "process exit left its private master directory"
    end
  end

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
      launcher = -> { Open3.popen3("python3", "-u", "-c", harness, WORKER, server, outside) }
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
      result = Net::Connector::Storage::AtomicFile.stub(:write_stream, ->(*) { raise IOError, "disk full" }) do
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

  def test_binary_upload_and_history_use_bounded_worker_reads
    patch = <<~PYTHON
      original_fdopen = worker.os.fdopen
      class BoundedFile:
          def __init__(self, file): self.file = file
          def __enter__(self): return self
          def __exit__(self, *args): return self.file.__exit__(*args)
          def __getattr__(self, name): return getattr(self.file, name)
          def read(self, size=-1):
              if size < 1 or size > 65536: raise ValueError("unbounded file read")
              return self.file.read(size)
      worker.os.fdopen = lambda *args, **kwargs: BoundedFile(original_fdopen(*args, **kwargs))
    PYTHON
    body = "new\0\xff\n".b * 40_000
    with_archive(worker_patch: patch) do |archive, server, _|
      File.binwrite(File.join(server, "running-config.xml"), "old\0\xff".b)
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        File.binwrite(File.join(server, name), body)
        uploaded(device, name)
      end
      assert result.success?
      assert_equal body, File.binread(result.backup.local_path)
      assert_equal Digest::SHA256.hexdigest(body), result.backup.server_sha256
      assert_equal(["old\0\xff".b], Dir[File.join(server, "archive/*/previous/*")].map { |path| File.binread(path) })
      refute File.exist?(File.join(server, "running-config.xml"))
    end
  end

  def test_bad_stream_proof_or_trailer_keeps_staging_and_old_local_file
    patches = [
      'if values.get("phase") == "archived": values["bytes"] = 0',
      'if values.get("phase") == "archived": values["bytes"] = True',
      'if values.get("phase") == "archived": values["bytes"] = "10"',
      'if values.get("phase") == "archived": values["bytes"] = 67108865',
      'if values.get("phase") == "archived": values["bytes"] += 1',
      'if values.get("phase") == "archived": values["sha256"] = "invalid"',
      'if values.get("phase") == "archived": values["sha256"] = "0" * 64',
      'if values.get("phase") == "delivered": sys.stdout.buffer.write(b"extra")',
      'if values.get("phase") == "delivered": values["phase"] = "unexpected"',
      'if values.get("phase") == "delivered": raise ValueError("delivery interrupted")'
    ]
    patches.each do |mutation|
      patch = "original_send = worker.send\ndef send(**values):\n    #{mutation}\n    original_send(**values)\nworker.send = send\n"
      with_archive(worker_patch: patch) do |archive, server, reports|
        path = File.join(reports, "tftp", "#{device.backup_filename(style: :hostname_ip).delete_suffix(".txt")}.xml")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "old local")
        calls = 0
        result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
          calls += 1
          File.write(File.join(server, name), "new upload")
          uploaded(device, name)
        end
        assert_equal :reported_with_error, result.status, mutation
        assert_equal :device_reported, result.backup.verification, mutation
        assert_nil result.backup.local_path
        assert_equal "old local", File.read(path)
        assert_equal "new upload", File.read(File.join(server, "running-config.xml"))
        assert_equal 1, calls
      end
    end
  end

  def test_midstream_disk_failure_still_verifies_server_without_replaying_writes
    with_archive do |archive, server, reports|
      path = File.join(reports, "tftp", "#{device.backup_filename(style: :hostname_ip).delete_suffix(".txt")}.xml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "old local")
      create = Tempfile.method(:create)
      writes = uploads = 0
      failing = lambda do |*args, **options|
        file = create.call(*args, **options)
        write = file.method(:write)
        file.define_singleton_method(:write) do |chunk|
          writes += 1
          raise Errno::ENOSPC if writes == 2

          write.call(chunk)
        end
        file
      end
      result = Tempfile.stub(:create, failing) do
        archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
          uploads += 1
          File.write(File.join(server, name), "x" * 200_000)
          uploaded(device, name)
        end
      end
      assert_equal :reported_with_error, result.status
      assert_equal :server_verified, result.backup.verification
      assert_equal 200_000, result.backup.server_bytes
      assert_nil result.backup.local_path
      assert_equal "old local", File.read(path)
      assert_equal 200_000, File.size(File.join(server, "running-config.xml"))
      assert_equal 2, writes
      assert_equal 1, uploads
      assert_empty Dir[File.join(reports, "tftp/.net-connector-*")]
    end
  end

  def test_archive_cleanup_error_does_not_replace_upload_cancellation
    original = Interrupt.new("upload cancelled")
    with_archive(close_error: IOError.new("pipe close failed")) do |archive, _server, _reports, processes|
      assert_same original, assert_raises(Interrupt) {
        archive.upload_and_archive(device, started_at: Time.now.utc) { raise original }
      }
      assert(processes.all? { |ios, process| ios.all?(&:closed?) && !process.alive? })
    end
  end

  def test_local_storage_failures_preserve_server_evidence_and_committed_path
    %i[prepare temporary_file file_sync directory_sync].each do |stage|
      with_archive do |archive, server, reports|
        uploads = 0
        result = with_local_failure(stage, reports) do
          archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
            uploads += 1
            File.write(File.join(server, name), "verified upload")
            uploaded(device, name)
          end
        end
        assert_equal :reported_with_error, result.status, stage
        assert_equal :server_verified, result.backup.verification, stage
        assert_equal Digest::SHA256.hexdigest("verified upload"), result.backup.server_sha256
        assert_equal "verified upload", File.read(File.join(server, "running-config.xml"))
        assert_equal 1, uploads
        if stage == :directory_sync
          assert_equal "verified upload", File.read(result.backup.local_path)
        else
          assert_nil result.backup.local_path
          assert_empty Dir[File.join(reports, "tftp/*.xml")]
        end
        assert_empty Dir[File.join(reports, "tftp/.net-connector-*")]
      end
    end
  end

  def test_stream_cancellation_and_throw_clean_temporary_files_and_processes
    %i[interrupt throw].each do |kind|
      with_archive(close_error: IOError.new("pipe close failed")) do |archive, server, reports, processes|
        create = Tempfile.method(:create)
        cancellation = Interrupt.new("stream cancelled")
        wrapper = lambda do |*args, **options|
          file = create.call(*args, **options)
          file.define_singleton_method(:write) do |*|
            raise cancellation if kind == :interrupt

            throw :cancel_stream, :cancelled
          end
          close = file.method(:close)
          file.define_singleton_method(:close) { close.call; raise IOError, "temporary close failed" }
          file
        end
        operation = lambda do
          Tempfile.stub(:create, wrapper) do
            archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
              File.write(File.join(server, name), "x" * 200_000)
              uploaded(device, name)
            end
          end
        end
        if kind == :interrupt
          assert_same cancellation, assert_raises(Interrupt, &operation)
        else
          assert_equal :cancelled, catch(:cancel_stream) { operation.call }
        end
        assert_empty Dir[File.join(reports, "tftp/*")]
        assert_empty Dir[File.join(reports, "tftp/.net-connector-*")]
        assert_equal 200_000, File.size(File.join(server, "running-config.xml"))
        assert(processes.all? { |ios, process| ios.all?(&:closed?) && !process.alive? })
      end
    end
  end

  def test_worker_rejects_file_mutation_during_copy_or_delivery
    %w[copy delivery].each do |stage|
      patch = <<~PYTHON
        original_read = worker.read_file
        def read_file(parent, name, missing=False, consume=None):
            matches = (name == "running-config.xml") == (#{stage.inspect} == "copy")
            if consume is not None and matches:
                original_consume = consume
                changed = False
                def consume(chunk):
                    nonlocal changed
                    size = original_consume(chunk)
                    if not changed:
                        changed = True
                        fd = worker.os.open(name, worker.os.O_WRONLY, dir_fd=parent)
                        try:
                            worker.os.write(fd, b"changed")
                            worker.os.fsync(fd)
                        finally:
                            worker.os.close(fd)
                    return size
            return original_read(parent, name, missing=missing, consume=consume)
        worker.read_file = read_file
      PYTHON
      with_archive(worker_patch: patch) do |archive, server, reports|
        result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
          File.write(File.join(server, name), "x" * 200_000)
          uploaded(device, name)
        end
        assert_equal :reported_with_error, result.status, stage
        assert_equal :device_reported, result.backup.verification, stage
        assert_nil result.backup.local_path
        assert_empty Dir[File.join(reports, "tftp/*.xml")]
        assert File.exist?(File.join(server, "running-config.xml"))
      end
    end
  end

  def test_empty_history_is_retained_and_oversized_upload_is_rejected
    with_archive do |archive, server, reports|
      File.write(File.join(server, "running-config.xml"), "")
      result = archive.upload_and_archive(device, started_at: Time.now.utc) do |name|
        File.open(File.join(server, name), "wb") { |file| file.truncate((64 * 1024 * 1024) + 1) }
        uploaded(device, name)
      end
      assert_equal :reported_with_error, result.status
      assert_equal :device_reported, result.backup.verification
      assert_equal([0], Dir[File.join(server, "archive/*/previous/*")].map { |path| File.size(path) })
      assert_equal (64 * 1024 * 1024) + 1, File.size(File.join(server, "running-config.xml"))
      assert_empty Dir[File.join(reports, "tftp/*.xml")]
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
                      launcher: -> { Open3.popen3("python3", "-u", WORKER) })
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
      assert_includes File.read(File.join(reports, "summary.txt")), "TFTP server files: verified 3, unverified 0."
    end
  end

  private

  def with_local_failure(stage, reports, &)
    storage = Net::Connector::Storage
    target = File.join(reports, "tftp")
    if stage == :prepare
      prepare = storage::Directory.method(:prepare)
      replacement = ->(path) { path == target ? (raise Errno::EACCES) : prepare.call(path) }
      storage::Directory.stub(:prepare, replacement, &)
    elsif stage == :temporary_file
      Tempfile.stub(:create, ->(*) { raise Errno::ENOSPC }, &)
    elsif stage == :file_sync
      create = Tempfile.method(:create)
      replacement = lambda do |*args, **options|
        file = create.call(*args, **options)
        file.define_singleton_method(:fsync) { raise Errno::EIO }
        file
      end
      Tempfile.stub(:create, replacement, &)
    else
      open = File.method(:open)
      replacement = lambda do |path, *args, **options, &block|
        file = open.call(path, *args, **options)
        file.define_singleton_method(:fsync) { raise Errno::EIO } if path == target && file.stat.directory?
        next file unless block

        begin
          block.call(file)
        ensure
          file.close
        end
      end
      File.stub(:open, replacement, &)
    end
  end

  def closed_client_reference(directory)
    archive = N::SSH::Archive::Client.new(directory: directory, root: "ssh://archive@backup.example/srv/tftp", password: "private-fixture")
    archive.stub(:authenticate_master, true) { archive.stub(:prepare_archive, nil) { archive.prepare } }
    archive.close
    WeakRef.new(archive)
  end

  def device(host = "192.0.2.1")
    N::Device.from_row({ "ip" => host, "name" => "edge", "vendor" => "Palo Alto Networks" }, rules: N::Rules.new)
  end

  def uploaded(item, path)
    receipt = Net::Connector::TftpReceipt.new(server: "192.0.2.10", path: path, completed_at: Time.now.utc)
    N::Outcome.new(device: item, status: :reported_uploaded, backup: receipt, error_code: nil, error_type: nil)
  end

  def with_archive(worker_patch: nil, close_error: nil)
    Dir.mktmpdir do |root|
      server = File.join(File.realpath(root), "server")
      reports = File.join(File.realpath(root), "reports")
      FileUtils.mkdir_p([server, reports])
      arguments = ["python3", "-u", WORKER]
      if worker_patch
        harness = <<~PYTHON
          import importlib.util, sys
          sys.dont_write_bytecode = True
          spec = importlib.util.spec_from_file_location("worker", sys.argv[1])
          worker = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(worker)
          #{worker_patch}
          try:
              worker.run()
          except Exception:
              print('{"ok": false, "error": "tftp_archive_failed"}', flush=True)
        PYTHON
        arguments = ["python3", "-u", "-c", harness, WORKER]
      end
      processes = []
      launcher = lambda do
        handles = Open3.popen3(*arguments)
        input, output, error, process = handles
        processes << [[input, output, error], process]
        if close_error
          close = input.method(:close)
          input.define_singleton_method(:close) { close.call; raise close_error }
        end
        handles
      end
      archive = N::SSH::Archive::Client.new(directory: reports, root: "ssh://archive@backup.example#{server}", launcher: launcher)
      yield archive, server, reports, processes
    ensure
      archive&.close
    end
  end
end
