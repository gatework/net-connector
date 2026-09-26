# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require_relative "../script/release"

class ReleaseTest < Minitest::Test
  def test_extracts_only_the_selected_version
    changelog = "# Changelog\n\n## Unreleased\n\n## 0.2.0 - 2026-09-12\n\n- New API.\n\n## 0.1.1\n\n- Old API.\n"
    assert_equal "- New API.", Release.release_notes(changelog, "0.2.0")
  end

  def test_rejects_unreleased_missing_empty_or_invalid_versions
    ["## Unreleased\n- Pending.\n## 0.2.0\n- Ready.", "## 0.1.1\n- Old.", "## 0.2.0\n"].each do |changelog|
      assert_raises(RuntimeError) { Release.release_notes(changelog, "0.2.0") }
    end
    assert_raises(RuntimeError) { Release.release_notes("## 0.2.0.rc1\n- Preview.", "0.2.0.rc1") }
    assert_raises(RuntimeError) { Release.release_notes("## Unreleased \t\n- Pending.\n## 0.2.0\n- Ready.", "0.2.0") }
  end

  def test_dry_run_verifies_the_artifact_without_remote_calls
    with_package do |release, artifact|
      release.stub(:github, ->(*) { flunk "dry run contacted GitHub" }) do
        release.stub(:get, ->(*) { flunk "dry run contacted RubyGems" }) do
          capture_io { release.run }
        end
      end
      directory = Dir.glob(File.join("tmp", "release", Net::Connector::VERSION, "candidate-*")).fetch(0)
      checksum = File.read(File.join(directory, "SHA256SUMS"))
      assert_equal "#{Digest::SHA256.file(artifact).hexdigest}  #{File.basename(artifact)}\n", checksum
      assert_equal "- Release fixture.\n", File.read(File.join(directory, "release-notes.md"))
      File.write(artifact, "another build")
      assert_equal checksum.split.first, Digest::SHA256.file(File.join(directory, File.basename(artifact))).hexdigest
    end
  end

  def test_rubygems_only_publishes_the_verified_copy_without_github
    with_package do |_release, artifact|
      release = Release.new(artifact: artifact, rubygems_only: true)
      bytes = File.binread(artifact)
      checksum = Digest::SHA256.hexdigest(bytes)
      published = false
      capture = ->(*arguments) { arguments.include?("rev-parse") ? "verified" : "" }
      get = lambda do |path|
        if path.start_with?("/downloads/")
          Struct.new(:code, :body).new("200", bytes)
        elsif published
          Struct.new(:code, :body).new("200", JSON.generate("sha" => checksum, "yanked" => false))
        else
          Struct.new(:code, :body).new("404", "")
        end
      end
      push = lambda do |*arguments|
        candidate = arguments.fetch(2)
        assert_equal ["gem", "push", candidate, "--host", "https://rubygems.org"], arguments
        assert_match %r{/tmp/release/#{Regexp.escape(Net::Connector::VERSION)}/candidate-[^/]+/}, candidate
        assert_equal bytes, File.binread(candidate)
        refute_equal File.expand_path(artifact), candidate
        published = true
      end
      release.stub(:capture, capture) do
        release.stub(:get, get) do
          release.stub(:system, push) do
            release.stub(:github, ->(*) { flunk "RubyGems-only release contacted GitHub" }) do
              release.stub(:publish_github, -> { flunk "RubyGems-only release published to GitHub" }) do
                [nil, "true"].each do |github_actions|
                  with_environment("GITHUB_ACTIONS" => github_actions,
                                   "GEM_HOST_API_KEY" => (github_actions ? "test-only-api-key" : nil)) do
                    published = false
                    output, = capture_io { release.run }
                    assert_includes output, "SHA256 verified"
                    assert published
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def test_ci_publish_requires_an_api_key_before_pushing
    release = Release.new(rubygems_only: true)
    release.instance_variable_set(:@artifact, __FILE__)
    release.instance_variable_set(:@sha256, Digest::SHA256.file(__FILE__).hexdigest)
    release.stub(:registry_version, nil) do
      release.stub(:system, ->(*) { flunk "pushed without a CI API key" }) do
        [nil, ""].each do |api_key|
          with_environment("GITHUB_ACTIONS" => "true", "GEM_HOST_API_KEY" => api_key) do
            error = assert_raises(RuntimeError) { release.send(:publish_rubygems) }
            assert_includes error.message, "RUBYGEMS_API_KEY"
          end
        end
      end
    end
  end

  def test_rubygems_only_rejects_uncommitted_source_before_publishing
    with_package do |_release, artifact|
      release = Release.new(artifact: artifact, rubygems_only: true)
      release.stub(:capture, " M payload.rb") do
        release.stub(:get, ->(*) { flunk "uncommitted source contacted RubyGems" }) do
          assert_match "Commit all source changes", assert_raises(RuntimeError) { release.run }.message
        end
      end
    end
  end

  def test_rubygems_only_rechecks_source_after_verification
    with_package do |_release, artifact|
      release = Release.new(artifact: artifact, rubygems_only: true)
      statuses = ["", " M payload.rb"]
      capture = ->(*arguments) { arguments.include?("rev-parse") ? "verified" : statuses.shift }
      release.stub(:capture, capture) do
        release.stub(:get, ->(*) { flunk "changed source contacted RubyGems" }) do
          with_environment("GITHUB_ACTIONS" => "true", "GEM_HOST_API_KEY" => nil) do
            capture_io do
              assert_match "Source changed", assert_raises(RuntimeError) { release.run }.message
            end
          end
        end
      end
    end
  end

  def test_rejects_a_package_from_different_source
    with_package do |release, _artifact|
      File.write("lib/fixture.rb", "puts :changed\n")
      assert_match "Artifact differs from source", assert_raises(RuntimeError) { release.send(:verify_package) }.message
    end
  end

  def test_artifact_retry_cannot_bypass_source_secret_scanning
    with_package do |release, _artifact|
      File.write("lib/fixture.rb", "endpoint = #{[10, 24, 8, 16].join(".").inspect}\n")
      release.stub(:publish_github, -> { flunk "published with sensitive source" }) do
        release.stub(:publish_rubygems, -> { flunk "pushed with sensitive source" }) do
          capture_io do
            assert_match "Secret scan failed", assert_raises(RuntimeError) { release.run }.message
          end
        end
      end
    end
  end

  def test_package_scan_rejects_a_secret_even_when_artifact_matches_source
    with_package do |release, _artifact|
      File.write("lib/fixture.rb", "endpoint = #{[10, 24, 8, 16].join(".").inspect}\n")
      capture_io { Gem::Package.build(Gem::Specification.load(File.expand_path("net-connector.gemspec"))) }
      capture_io do
        error = assert_raises(RuntimeError) { release.send(:verify_package) }
        assert_includes error.message, "package"
      end
    end
  end

  def test_forbidden_package_file_is_rejected_even_if_added_to_the_gemspec
    with_package do |release, _artifact|
      File.write(".env", "fixture-only\n")
      spec = Gem::Specification.load(File.expand_path("net-connector.gemspec"))
      spec.files += [".env"]
      capture_io { Gem::Package.build(spec) }
      Gem::Specification.stub(:load, spec) do
        assert_match "Unexpected packaged file", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      end
    end
  end

  def test_resolves_repository_without_embedding_a_personal_account
    release = Release.new(repository: "example/net-connector")
    release.send(:resolve_repository)
    assert_equal "example/net-connector", release.instance_variable_get(:@repository)
    release = Release.new(repository: "../unexpected")
    assert_raises(RuntimeError) { release.send(:resolve_repository) }
  end

  def test_rejects_different_installation_metadata_even_with_identical_source_files
    with_package do |release, _artifact|
      expected = Gem::Specification.load(File.expand_path("net-connector.gemspec")).dup
      expected.add_runtime_dependency "unexpected-dependency", "= 1.0.0"
      Gem::Specification.stub(:load, expected) do
        assert_match "metadata", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      end
      expected = Gem::Specification.load(File.expand_path("net-connector.gemspec")).dup
      expected.extensions = ["lib/fixture.rb"]
      Gem::Specification.stub(:load, expected) do
        assert_match "metadata", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      end
    end
  end

  def test_registry_errors_are_not_treated_as_an_unpublished_version
    release = Release.new(repository: "example/net-connector")
    response = Struct.new(:code, :body).new("503", "unavailable")
    release.stub(:get, response) { assert_raises(RuntimeError) { release.send(:registry_version) } }
  end

  def test_rejects_overwriting_a_published_version_or_reusing_a_yanked_version
    release = Release.new(repository: "example/net-connector")
    release.instance_variable_set(:@sha256, "expected")
    [{ "sha" => "different", "yanked" => false }, { "sha" => "expected", "yanked" => true }].each do |version|
      assert_raises(RuntimeError) { release.send(:verify_registry_checksum, version) }
    end
  end

  def test_existing_registry_version_is_downloaded_and_verified_without_pushing_again
    release = Release.new(repository: "example/net-connector")
    bytes = File.binread(__FILE__)
    release.instance_variable_set(:@artifact, __FILE__)
    checksum = Digest::SHA256.hexdigest(bytes)
    release.instance_variable_set(:@sha256, checksum)
    response = Struct.new(:code, :body).new("200", bytes)
    release.stub(:registry_version, { "sha" => checksum, "yanked" => false }) do
      release.stub(:system, ->(*) { flunk "repushed an existing gem" }) do
        release.stub(:get, response) { capture_io { release.send(:publish_rubygems) } }
        response.body = "different bytes"
        release.stub(:get, response) { assert_raises(RuntimeError) { release.send(:publish_rubygems) } }
      end
    end
  end

  def test_remote_tag_must_point_to_the_verified_commit
    release = Release.new(repository: "example/net-connector")
    release.instance_variable_set(:@commit, "verified")
    capture = ->(*arguments) { arguments.include?("rev-parse") ? "verified" : "" }
    github = lambda do |path, **|
      { "status" => (path.end_with?("...main") ? "ahead" : "behind") }
    end
    release.stub(:capture, capture) do
      release.stub(:github, github) do
        assert_match "another commit", assert_raises(RuntimeError) { release.send(:verify_remote_source) }.message
      end
    end
  end

  def test_package_validation_uses_archive_modes_regardless_of_umask
    with_package do |release, artifact|
      File.chmod(0o755, "lib/fixture.rb")
      capture_io { Gem::Package.build(Gem::Specification.load(File.expand_path("net-connector.gemspec"))) }
      previous_umask = File.umask(0o077)
      begin
        release.send(:verify_package)
        assert File.file?(artifact)
        File.chmod(0o644, "lib/fixture.rb")
        assert_match "permissions differ", assert_raises(RuntimeError) { release.send(:verify_package) }.message
      ensure
        File.umask(previous_umask)
      end
    end
  end

  def test_incomplete_github_asset_has_an_explicit_recovery_message
    release = Release.new(repository: "example/net-connector")
    release.instance_variable_set(:@artifact, __FILE__)
    release.instance_variable_set(:@sha256, Digest::SHA256.file(__FILE__).hexdigest)
    release.instance_variable_set(:@checksum_file, "SHA256SUMS")
    remote = { "assets" => [{ "name" => "SHA256SUMS", "state" => "starter" }] }
    release.stub(:github_release, remote) do
      error = assert_raises(RuntimeError) { release.send(:publish_github) }
      assert_match "Incomplete GitHub asset: SHA256SUMS", error.message
      assert_match "stop any active upload", error.message
    end
  end

  private

  # 发布测试显式控制凭据环境，避免本机登录状态或 CI 标记影响用例结果。
  def with_environment(values)
    previous = values.to_h { |name, _value| [name, ENV.fetch(name, nil)] }
    begin
      values.each { |name, value| ENV[name] = value }
      yield
    ensure
      previous.each { |name, value| ENV[name] = value }
    end
  end

  def with_package
    Dir.mktmpdir("net-connector-release-test-") do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p("lib")
        File.write("lib/fixture.rb", "puts :original\n")
        File.write("CHANGELOG.md", "## #{Net::Connector::VERSION}\n\n- Release fixture.\n")
        File.write("net-connector.gemspec", <<~RUBY)
          Gem::Specification.new do |spec|
            spec.name = "net-connector"
            spec.version = "#{Net::Connector::VERSION}"
            spec.summary = "Release test fixture"
            spec.authors = ["Test"]
            spec.license = "MIT"
            spec.homepage = "https://github.com/example/net-connector"
            spec.files = ["lib/fixture.rb", "CHANGELOG.md"]
          end
        RUBY
        artifact = nil
        capture_io { artifact = Gem::Package.build(Gem::Specification.load(File.expand_path("net-connector.gemspec"))) }
        yield Release.new(artifact: artifact, dry_run: true), artifact
      end
    end
  end
end
