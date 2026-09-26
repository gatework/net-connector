# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "open3"
require "tmpdir"
require_relative "tools"

# 只输出文件、行号与规则名；匹配文本、密钥值和原始扫描日志都不进入 CI 日志。
module SecretScan
  CONFIG = File.join(BuildTools::ROOT, ".gitleaks.toml")
  LOCAL_DIRECTORIES = %w[.git .bundle .idea .vscode .ssh .gem .secrets secrets tmp pkg vendor
                         backups exports logs log reports coverage .rubocop_cache .ruby-lsp .yardoc doc rdoc].freeze
  SOURCE_DIRECTORIES = %w[lib exe test examples docs script .github].freeze
  SOURCE_FILES = %w[Gemfile Rakefile net-connector.gemspec README.md CHANGELOG.md LICENSE
                    .gitignore .gitleaks.toml .rubocop.yml .env.example].freeze

  def self.forbidden_path?(path)
    parts = path.split("/")
    name = parts.last.to_s
    return true if path.start_with?("/") || parts.include?("..") || LOCAL_DIRECTORIES.include?(parts.first)
    return true if path.start_with?("examples/backups/")
    return true if name.start_with?(".env") && !name.end_with?(".example")

    name.match?(/\A(?:credentials(?:\.ya?ml)?|known_hosts(?:\.old)?|id_(?:rsa|ed25519|ecdsa|dsa)|config\.ya?ml|Gemfile\.lock)\z/) ||
      name.match?(/\.(?:pem|key|p12|pfx|log|gem)\z/i) || name.match?(/\.local\.ya?ml\z/)
  end

  def self.git_root?(root)
    output, _errors, status = Open3.capture3("git", "-C", root, "rev-parse", "--show-toplevel")
    status.success? && File.realpath(output.strip) == File.realpath(root)
  end

  def self.source_files(root)
    if git_root?(root)
      output, _errors, status = Open3.capture3("git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
      raise "Cannot enumerate source files" unless status.success?

      paths = output.split("\0").uniq
    else
      paths = SOURCE_FILES.select { |path| File.file?(File.join(root, path)) }
      SOURCE_DIRECTORIES.each do |directory|
        base = File.join(root, directory)
        next unless File.directory?(base)

        Find.find(base) do |file|
          relative = file.delete_prefix("#{root}/")
          Find.prune if File.directory?(file) && forbidden_path?("#{relative}/")
          paths << relative if File.file?(file) || File.symlink?(file)
        end
      end
    end
    paths.sort
  end

  def self.source(root: Dir.pwd, history: true)
    root = File.expand_path(root)
    files = source_files(root)
    raise "No source files to scan" if files.empty?

    invalid = files.select { |path| forbidden_path?(path) }
    raise "Local or sensitive files included in source: #{invalid.join(", ")}" unless invalid.empty?

    Dir.mktmpdir("net-connector-source-scan-") do |staging|
      files.each do |path|
        original = File.join(root, path)
        raise "Source contains a symlink: #{path}" if File.symlink?(original)
        next unless File.file?(original)
        raise "Source file is outside checkout: #{path}" unless File.realpath(original).start_with?("#{File.realpath(root)}/")

        destination = File.join(staging, path)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(original, destination)
      end
      directory(staging, label: "source", report_root: root)
    end
    if history && git_root?(root)
      _head, _errors, status = Open3.capture3("git", "-C", root, "rev-parse", "--verify", "HEAD")
      unless status.success?
        puts "Secret history scan unavailable: repository has no commits"
        return
      end
      shallow, _errors, status = Open3.capture3("git", "-C", root, "rev-parse", "--is-shallow-repository")
      raise "Cannot determine Git history completeness" unless status.success?
      raise "Secret history scan requires a full checkout (fetch-depth: 0)" if shallow.strip == "true"

      run("git", root, label: "history", report_root: root, extra: ["--log-opts=--all"])
    elsif history
      puts "Secret history scan unavailable: source directory has no Git metadata"
    end
  end

  def self.directory(path, label: "package", report_root: Dir.pwd)
    run("dir", File.expand_path(path), label: label, report_root: report_root)
  end

  def self.run(mode, path, label:, report_root:, extra: [])
    executable = BuildTools.path("gitleaks")
    Dir.mktmpdir("net-connector-secret-report-") do |private_directory|
      report = File.join(private_directory, "report.json")
      ignore = File.join(private_directory, "empty.ignore")
      File.write(ignore, "", mode: "w", perm: 0o600)
      arguments = [executable, mode, path, "--config", CONFIG, "--no-banner", "--no-color", "--redact=100",
                   "--ignore-gitleaks-allow", "--gitleaks-ignore-path", ignore, "--max-decode-depth=2",
                   "--max-archive-depth=3", "--report-format=json", "--report-path", report, "--log-level=error", *extra]
      _output, _errors, status = Open3.capture3(*arguments)
      raise "Secret scanner did not produce a report (#{label}, exit #{status.exitstatus})" unless File.file?(report)

      findings = JSON.parse(File.read(report))
      safe = findings.map { |item| { rule: item.fetch("RuleID"), file: item.fetch("File").delete_prefix("#{path}/"), line: item.fetch("StartLine") } }
      output_directory = File.join(report_root, "tmp", "security")
      FileUtils.mkdir_p(output_directory, mode: 0o700)
      output_path = File.join(output_directory, "#{label}.json")
      File.write(output_path, JSON.pretty_generate(safe) + "\n", mode: "w", perm: 0o600)
      File.chmod(0o600, output_path)
      unless status.success? && safe.empty?
        safe.each { |item| warn "#{item[:file]}:#{item[:line]}: #{item[:rule]} [REDACTED]" }
        raise "Secret scan failed (#{label}, #{safe.size} findings, exit #{status.exitstatus}); review the redacted report"
      end
      puts "Secret scan passed: #{label}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    SecretScan.source(root: BuildTools::ROOT)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
