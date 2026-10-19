# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"
require_relative "../lib/net/connector/netdisco/ssh/archive/client"

class SshAuthenticationTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_password_dialogue_is_private_and_only_answers_once
    script = 'STDOUT.sync=true; print "Password: "; line=STDIN.gets; abort "Permission denied" unless line=="private-fixture\n"'
    stdout, stderr = capture_io do
      assert N::SSH::Authentication.respond([Gem.ruby, "-e", script], password: "private-fixture")
    end
    assert_empty stdout
    assert_empty stderr
    repeated = 'STDOUT.sync=true; print "Password: "; STDIN.gets; print "Password: "; sleep 5'
    refute N::SSH::Authentication.respond([Gem.ruby, "-e", repeated], password: "private-fixture")
  end

  def test_server_password_is_excluded_from_public_policy_and_snapshots
    environment = { "NC_TFTP_SSH_PASSWORD" => "private-fixture" }
    settings = N::Settings.new(env: environment)
    assert_equal "private-fixture", settings.tftp_ssh_password
    refute_includes settings.public_config.to_s, "private-fixture"
    assert_nil settings.snapshot(mode: :tftp).tftp_ssh_password
    environment["NC_TFTP_SSH_PASSWORD"] = "rotated-fixture"
    assert_equal "rotated-fixture", settings.tftp_ssh_password
  end

  def test_configured_password_never_enters_ssh_arguments
    Dir.mktmpdir do |directory|
      archive = N::SSH::Archive::Client.new(directory: directory, root: "ssh://archive@backup.example/srv/tftp", password: "private-fixture")
      responder = lambda do |args, password:|
        assert_equal "private-fixture", password
        refute_includes args.join(" "), password
        assert_includes args, "NumberOfPasswordPrompts=1"
        assert_includes args, "BatchMode=no"
        true
      end
      N::SSH::Authentication.stub(:respond, responder) do
        archive.stub(:system, ->(*) { true }) do
          archive.stub(:prepare_archive, nil) { archive.prepare }
        end
      end
    ensure
      archive&.close
    end
  end

  def test_configured_password_failure_does_not_claim_password_is_missing
    Dir.mktmpdir do |directory|
      archive = N::SSH::Archive::Client.new(directory: directory, root: "ssh://archive@backup.example/srv/tftp", password: "private-fixture")
      N::SSH::Authentication.stub(:respond, false) do
        2.times do
          error = assert_raises(N::SSH::Archive::Client::AuthenticationUnavailable) { archive.prepare }
          assert_includes error.message, "已读取 NC_TFTP_SSH_PASSWORD"
          refute_includes error.message, "请在项目根目录 .env 设置"
          refute_includes error.message, "private-fixture"
        end
      end
    ensure
      archive&.close
    end
  end

  def test_failed_server_authentication_stops_cli_before_resolving_device_credentials
    Dir.mktmpdir do |directory|
      path = File.join(directory, "backup.yml")
      File.write(path, { "backup" => { "directory" => File.join(directory, "backups") }, "tftp" => {
        "server" => "192.0.2.10", "verification_roots" => { "192.0.2.10" => "ssh://archive@backup.example/srv/tftp" }
      } }.to_yaml)
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }])
      archive = N::SSH::Archive::Client.new(directory: directory, root: "ssh://archive@backup.example/srv/tftp")
      error = StringIO.new
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { flunk "device credentials must not be requested" }]) do
        N::SSH::Archive::Client.stub(:new, archive) do
          archive.stub(:system, ->(*) { false }) do
            status = N::CLI::Backup.new(mode: :tftp, argv: ["--config", path, "--non-interactive"], env: {},
                                        output: StringIO.new, error: error).run
            assert_equal 2, status
          end
        end
      end
      assert_includes error.string, "NC_TFTP_SSH_PASSWORD"
      assert_includes error.string, "已停止，未连接设备"
      refute_includes error.string, "\e["
    ensure
      archive&.close
    end
  end

  def test_cancelled_master_authentication_reclaims_its_private_directory
    Dir.mktmpdir do |reports|
      archive = N::SSH::Archive::Client.new(directory: reports, root: "ssh://archive@backup.example/srv/tftp")
      original = Dir.method(:mktmpdir)
      created = nil
      allocator = ->(*args) { created = original.call(*args) }
      interruption = Interrupt.new("cancel authentication")
      error = Dir.stub(:mktmpdir, allocator) do
        archive.stub(:authenticate_master, -> { raise interruption }) do
          assert_raises(Interrupt) { archive.prepare }
        end
      end
      assert_same interruption, error
      refute File.exist?(created)
    ensure
      archive&.close
      FileUtils.remove_entry_secure(created) if created && File.directory?(created)
    end
  end

  def test_master_cleanup_failure_does_not_replace_authentication_interruption
    Dir.mktmpdir do |reports|
      archive = N::SSH::Archive::Client.new(directory: reports, root: "ssh://archive@backup.example/srv/tftp")
      original = Dir.method(:mktmpdir)
      created = nil
      allocator = ->(*args) { created = original.call(*args) }
      interruption = Interrupt.new("cancel authentication")
      cleanup_attempted = false
      error = Dir.stub(:mktmpdir, allocator) do
        archive.stub(:authenticate_master, -> { raise interruption }) do
          FileUtils.stub(:remove_entry_secure, ->(*) { cleanup_attempted = true; raise IOError, "cleanup failed" }) do
            assert_raises(Interrupt) { archive.prepare }
          end
        end
      end
      assert_same interruption, error
      assert cleanup_attempted
    ensure
      archive&.close
      FileUtils.remove_entry_secure(created) if created && File.directory?(created)
    end
  end
end
