#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "rubygems/package"
require "tmpdir"
require_relative "../lib/net/connector/version"
require_relative "package"

# 本地使用 gem / gh 已有的登录状态；CI 传入测试过的包，发布阶段不重新构建。
class Release
  GEM_HOST = "https://rubygems.org"

  def initialize(artifact: nil, dry_run: false, rubygems_only: false, repository: nil)
    @repository = repository || ENV["GITHUB_REPOSITORY"]
    @version = Net::Connector::VERSION
    @tag = "v#{@version}"
    @artifact = File.expand_path(artifact || "tmp/ci/net-connector-#{@version}.gem")
    @dry_run = dry_run
    @rubygems_only = rubygems_only
    @build = artifact.nil?
  end

  def run
    notes = self.class.release_notes(File.read("CHANGELOG.md"), @version)
    unless @dry_run || capture("git", "status", "--porcelain").empty?
      raise "Commit all source changes before publishing"
    end

    @commit = capture("git", "rev-parse", "HEAD") unless @dry_run
    resolve_repository unless @dry_run || @rubygems_only
    if @build
      command("bash", "script/ci")
    else
      # 复用产物不能绕过源码、历史和发布说明的敏感数据检查。
      SecretScan.source
    end
    # 独占目录中的副本贯穿校验和上传，其他构建不会改变本次发布的字节。
    directory = File.join("tmp", "release", @version)
    FileUtils.mkdir_p(directory)
    directory = Dir.mktmpdir("candidate-", directory)
    candidate = File.join(directory, "net-connector-#{@version}.gem")
    FileUtils.cp(@artifact, candidate)
    @artifact = File.expand_path(candidate)
    verify_package
    @sha256 = Digest::SHA256.file(@artifact).hexdigest
    @checksum_file = File.join(directory, "SHA256SUMS")
    @notes_file = File.join(directory, "release-notes.md")
    File.write(@checksum_file, "#{@sha256}  #{File.basename(@artifact)}\n")
    File.write(@notes_file, "#{notes}\n")
    puts "Verified #{@tag}: #{@sha256}\nArtifact: #{@artifact}"
    return puts "Dry run complete: #{@artifact}" if @dry_run

    if @rubygems_only
      verify_local_source
    else
      verify_remote_source
      verify_registry_checksum(registry_version)
      publish_github
    end
    publish_rubygems
  end

  # 有未归档的变更时拒绝发布，避免把新接口放进旧版本或遗漏发布说明。
  def self.release_notes(changelog, version)
    raise "Use a stable X.Y.Z version" unless /\A\d+\.\d+\.\d+\z/.match?(version)

    sections = changelog.split(/^## /).drop(1).map do |section|
      heading, body = section.split("\n", 2)
      [heading.strip, body]
    end
    unreleased = sections.find { |heading, _body| heading == "Unreleased" }
    if unreleased && !unreleased[1].to_s.strip.empty?
      raise "Move Unreleased changes into the versioned changelog before releasing"
    end

    section = sections.find do |heading, _body|
      /\A#{Regexp.escape(version)}(?: - \d{4}-\d{2}-\d{2})?\z/.match?(heading)
    end
    raise "Missing release notes for #{version}" unless section && !section[1].to_s.strip.empty?

    section[1].strip
  end

  private

  def capture(*arguments)
    output, error, status = Open3.capture3(*arguments)
    raise "#{arguments.first} failed: #{error.strip}" unless status.success?

    output.strip
  end

  def command(*arguments)
    raise "#{arguments.first} failed" unless system(*arguments)
  end

  def github(path, missing: false)
    output, error, status = Open3.capture3("gh", "api", "repos/#{@repository}/#{path}")
    return nil if missing && !status.success? && error.include?("HTTP 404")
    raise "GitHub API failed: #{error.strip}" unless status.success?

    JSON.parse(output)
  end

  def verify_local_source
    return if capture("git", "rev-parse", "HEAD") == @commit && capture("git", "status", "--porcelain").empty?

    raise "Source changed during verification; commit the changes and start again"
  end

  def verify_remote_source
    verify_local_source

    comparison = github("compare/#{@commit}...main")
    raise "Push this commit to #{@repository}/main first" unless %w[ahead identical].include?(comparison.fetch("status"))

    return unless github("git/ref/tags/#{@tag}", missing: true)
    return if github("compare/#{@tag}...#{@commit}").fetch("status") == "identical"

    raise "Remote tag #{@tag} points to another commit"
  end

  # CI 与本地重试使用完全相同的包清单、字节、权限和敏感数据校验。
  def verify_package
    PackageCheck.verify(@artifact)
  end

  def resolve_repository
    unless @repository
      origin = capture("git", "remote", "get-url", "origin")
      @repository = origin[%r{\A(?:git@github\.com:|https://github\.com/)([^/]+/[^/]+?)(?:\.git)?\z}, 1]
    end
    if @repository&.match?(%r{\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+\z}) &&
       !%w[. ..].include?(@repository.split("/").last)
      return
    end

    raise "Use a GitHub origin or --repository OWNER/REPO (or --rubygems-only)"
  end

  def get(path)
    uri = URI("#{GEM_HOST}#{path}")
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
  end

  def registry_version
    response = get("/api/v2/rubygems/net-connector/versions/#{@version}.json")
    return nil if response.code == "404"
    raise "RubyGems lookup failed: HTTP #{response.code}" unless response.code == "200"

    JSON.parse(response.body)
  end

  def verify_registry_checksum(version)
    return unless version
    return if !version.fetch("yanked") && version.fetch("sha") == @sha256

    raise "RubyGems already has different or yanked bytes for #{@version}; use the original artifact or a new version"
  end

  # gh 同时查找已发布版本和遗留草稿，REST 按标签查询只能找到已发布版本。
  def github_release
    output, error, status = Open3.capture3("gh", "release", "view", @tag, "--repo", @repository,
                                           "--json", "isDraft,assets")
    return nil if !status.success? && error.strip == "release not found"
    raise "GitHub Release lookup failed: #{error.strip}" unless status.success?

    JSON.parse(output)
  end

  # 先补齐 GitHub Release；RubyGems 认证失败时，已上传的原包仍可用于重试。
  def publish_github
    release = github_release
    raise "Verified artifact changed before publishing" unless Digest::SHA256.file(@artifact).hexdigest == @sha256

    assets = [@artifact, @checksum_file]
    if release
      existing, missing = assets.partition do |asset|
        entry = release.fetch("assets").find { |item| item.fetch("name") == File.basename(asset) }
        if entry && entry.fetch("state") != "uploaded"
          raise "Incomplete GitHub asset: #{entry.fetch("name")}; stop any active upload, remove the incomplete " \
                  "asset in GitHub Release, then retry with the same artifact"
        end
        entry
      end
      verify_github_assets(existing)
      missing.each { |asset| command("gh", "release", "upload", @tag, asset, "--repo", @repository) }
      verify_github_assets(missing)
      if release.fetch("isDraft")
        command("gh", "release", "edit", @tag, "--repo", @repository, "--target", @commit, "--draft=false")
      end
    else
      command("gh", "release", "create", @tag, *assets, "--repo", @repository, "--target", @commit,
              "--title", @tag, "--notes-file", @notes_file)
      verify_github_assets(assets)
    end
    unless github("compare/#{@tag}...#{@commit}").fetch("status") == "identical"
      raise "Published tag points to another commit"
    end

    puts "GitHub Release: https://github.com/#{@repository}/releases/tag/#{@tag}"
  end

  def verify_github_assets(assets)
    # 新上传的附件也读回核验，工作流成功不代替远端产物校验。
    Dir.mktmpdir("net-connector-release-readback-") do |directory|
      assets.each do |asset|
        name = File.basename(asset)
        command("gh", "release", "download", @tag, "--repo", @repository, "--pattern", name, "--dir", directory)
        unless Digest::SHA256.file(File.join(directory, name)).hexdigest == Digest::SHA256.file(asset).hexdigest
          raise "GitHub Release asset verification failed: #{name}"
        end
      end
    end
  end

  def publish_rubygems
    raise "Verified artifact changed before publishing" unless Digest::SHA256.file(@artifact).hexdigest == @sha256

    version = registry_version
    verify_registry_checksum(version)
    unless version
      if ENV["GITHUB_ACTIONS"] == "true" && ENV.fetch("GEM_HOST_API_KEY", "").empty?
        raise "Configure RubyGems Trusted Publishing for release.yml, or publish locally with the existing gem login"
      end

      pushed = system("gem", "push", @artifact, "--host", GEM_HOST)
      # 推送返回失败也先读取远端，避免连接中断后盲目重复上传。
      version = registry_version
      verify_registry_checksum(version)
      raise "gem push failed; check RubyGems authentication and retry with the same artifact" unless pushed || version
    end

    6.times do |attempt|
      response = get("/downloads/net-connector-#{@version}.gem")
      if response.code == "200"
        raise "Downloaded RubyGems artifact checksum differs" unless Digest::SHA256.hexdigest(response.body) == @sha256

        return puts "RubyGems: #{GEM_HOST}/gems/net-connector/versions/#{@version} (SHA256 verified)"
      end
      raise "RubyGems download failed: HTTP #{response.code}" unless response.code == "404"

      sleep 2 unless attempt == 5
    end
    raise "RubyGems download is not available yet; retry with the same artifact"
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |arguments|
    arguments.banner = "用法：ruby script/release.rb [--rubygems-only] [--dry-run] [--artifact PATH] [--repository OWNER/REPO]"
    arguments.on("--repository OWNER/REPO", "GitHub 仓库，默认读取 GITHUB_REPOSITORY 或 origin") do |value|
      options[:repository] = value
    end
    arguments.on("--rubygems-only", "只用现有 gem 登录发布到 RubyGems，不访问 GitHub") do
      options[:rubygems_only] = true
    end
    arguments.on("--artifact PATH", "发布已验证的 gem，不重新构建") do |path|
      options[:artifact] = File.expand_path(path)
    end
    arguments.on("--dry-run", "仅在本地构建和验证，不发布") { options[:dry_run] = true }
  end
  begin
    parser.parse!
    raise OptionParser::InvalidArgument, ARGV.join(" ") unless ARGV.empty?

    Dir.chdir(File.expand_path("..", __dir__)) { Release.new(**options).run }
  rescue StandardError => error
    warn "发布已中止：#{error.message}"
    exit 1
  end
end
