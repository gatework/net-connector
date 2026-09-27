# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../script/security"
require_relative "../script/package"

class SecurityTest < Minitest::Test
  def test_real_scanner_rejects_a_token_and_never_reports_its_value
    with_source do |directory|
      secret = ["ghp", "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"].join("_")
      File.write(File.join(directory, "lib", "leak.rb"), "access_token = #{secret.inspect} # gitleaks:allow\n")
      output, errors = capture_io do
        assert_raises(RuntimeError) { SecretScan.source(root: directory, history: false) }
      end
      report = File.read(File.join(directory, "tmp", "security", "source.json"))
      refute_empty JSON.parse(report)
      refute_includes [output, errors, report].join, secret
      assert_includes errors, "[REDACTED]"
      assert(JSON.parse(report).all? { |finding| finding.keys.sort == %w[file line rule] })
      assert_equal 0o600, File.stat(File.join(directory, "tmp", "security", "source.json")).mode & 0o777
    end
  end

  def test_network_credentials_and_private_addresses_are_rejected_but_examples_pass
    with_source do |directory|
      fixture = File.join(directory, "README.md")
      address = [10, 24, 8, 16].join(".")
      File.write(fixture, "host #{address}\nsnmp-server community #{%w[not a real community].join("-")}\n")
      capture_io { assert_raises(RuntimeError) { SecretScan.source(root: directory, history: false) } }
      rules = JSON.parse(File.read(File.join(directory, "tmp", "security", "source.json"))).map { |finding| finding.fetch("rule") }
      assert_includes rules, "network-private-address"
      assert_includes rules, "network-device-secret"
      File.write(fixture, "host 192.0.2.1\nNETDISCO_PASSWORD=replace-me\n")
      capture_io { SecretScan.source(root: directory, history: false) }
      assert_empty JSON.parse(File.read(File.join(directory, "tmp", "security", "source.json")))
    end
  end

  def test_common_device_credential_forms_cannot_bypass_the_source_scan
    with_source do |directory|
      fixture = File.join(directory, "README.md")
      secret = %w[fixture device secret 89371].join("-")
      prefixes = [%w[username admin privilege 15 secret 0], %w[password hash],
                  %w[local-user admin class manage password hash]]
      prefixes.each do |prefix|
        File.write(fixture, "#{prefix.join(" ")} #{secret}\n")
        capture_io { assert_raises(RuntimeError) { SecretScan.source(root: directory, history: false) } }
        report = JSON.parse(File.read(File.join(directory, "tmp", "security", "source.json")))
        assert_includes report.map { |finding| finding.fetch("rule") }, "network-device-secret", prefix.join(" ")
      end
    end
  end

  def test_netdisco_database_password_is_scanned_without_reporting_the_value
    with_source do |directory|
      secret = %w[fixture database credential 18379].join("-")
      File.write(File.join(directory, "README.md"), "export NETDISCO_DB_PASS=#{secret}\n")
      output, errors = capture_io do
        assert_raises(RuntimeError) { SecretScan.source(root: directory, history: false) }
      end
      report = File.read(File.join(directory, "tmp", "security", "source.json"))
      assert_includes JSON.parse(report).map { |finding| finding.fetch("rule") }, "environment-credential"
      refute_includes [output, errors, report].join, secret
    end
  end

  def test_gitignore_protects_local_data_but_keeps_templates_source_and_workflows
    with_source do |directory|
      git(directory, "init", "--quiet")
      FileUtils.cp(File.join(BuildTools::ROOT, ".gitignore"), directory)
      ignored = %w[.env .env.production .ssh/id_ed25519 credentials.yml config.yml device.key backups/device.cfg exports/device.cfg
                   logs/session.log examples/backups/run/config.txt tmp/ci/package.gem Gemfile.lock .idea/workspace.xml]
      ignored.each do |file|
        _output, _errors, status = Open3.capture3("git", "-C", directory, "check-ignore", "--no-index", file)
        assert status.success?, file
      end
      %w[.env.example .env.staging.example lib/net/connector/vendor/h3c.rb .github/workflows/ci.yml].each do |file|
        _output, _errors, status = Open3.capture3("git", "-C", directory, "check-ignore", "--no-index", file)
        refute status.success?, file
      end
      File.write(File.join(directory, ".env"), "placeholder\n")
      git(directory, "add", "--force", ".env")
      assert_match "sensitive files", assert_raises(RuntimeError) { SecretScan.source(root: directory, history: false) }.message
    end
  end

  def test_history_scan_rejects_a_deleted_secret
    with_source do |directory|
      git(directory, "init", "--quiet")
      git(directory, "config", "user.name", "Release fixture")
      git(directory, "config", "user.email", "release@example.invalid")
      secret_file = File.join(directory, "README.md")
      File.write(secret_file, "host #{[10, 24, 8, 16].join(".")}\n")
      git(directory, "add", "README.md")
      git(directory, "commit", "--quiet", "-m", "fixture with private address")
      File.write(secret_file, "host 192.0.2.1\n")
      git(directory, "add", "README.md")
      git(directory, "commit", "--quiet", "-m", "redact fixture")
      capture_io do
        error = assert_raises(RuntimeError) { SecretScan.source(root: directory) }
        assert_includes error.message, "history"
      end
      assert_empty JSON.parse(File.read(File.join(directory, "tmp", "security", "source.json")))
      refute_empty JSON.parse(File.read(File.join(directory, "tmp", "security", "history.json")))
    end
  end

  def test_missing_scanner_report_fails_closed
    with_source do |directory|
      status = Struct.new(:exitstatus) {
        def success? = true }.new(0)
      Open3.stub(:capture3, ["", "", status]) do
        error = assert_raises(RuntimeError) { SecretScan.directory(directory, report_root: directory) }
        assert_includes error.message, "did not produce a report"
      end
    end
  end

  def test_symlinks_cannot_copy_files_outside_the_checkout
    with_source do |directory|
      File.symlink(__FILE__, File.join(directory, "lib", "outside.rb"))
      assert_match "symlink", assert_raises(RuntimeError) { SecretScan.source(root: directory, history: false) }.message
    end
  end

  private

  def with_source
    Dir.mktmpdir("net-connector-security-test-") do |directory|
      FileUtils.mkdir_p(File.join(directory, "lib"))
      File.write(File.join(directory, "lib", "safe.rb"), "# frozen_string_literal: true\n")
      yield directory
    end
  end

  def git(directory, *arguments)
    _output, errors, status = Open3.capture3("git", "-C", directory, *arguments)
    assert status.success?, errors
  end
end
