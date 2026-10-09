# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"
require_relative "security"
require_relative "../lib/net/connector/version"

# CI 和发布共用包校验；校验归档本身，不能仅靠源码目录通过测试。
module PackageCheck
  METADATA = %i[name version platform summary description authors licenses homepage required_ruby_version
                required_rubygems_version require_paths metadata dependencies extensions executables bindir
                post_install_message].freeze

  def self.allowed_path?(path)
    return false if path.start_with?("/") || path.split("/").include?("..")

    path.match?(%r{\Alib/.+\.rb\z}) ||
      path.match?(%r{\Alib/net/connector/templates/(?:[^/]+\.textfsm|index)\z}) ||
      path.match?(%r{\Adocs/[^/]+\.md\z}) ||
      %w[bin/net-backup examples/backup.yml examples/inventory_sql.yml README.md LICENSE CHANGELOG.md SECURITY.md CONTRIBUTING.md].include?(path)
  end

  def self.build(root: Dir.pwd)
    root = File.expand_path(root)
    directory = File.join(root, "tmp", "ci")
    FileUtils.mkdir_p(directory)
    artifact = File.join(directory, "net-connector-#{Net::Connector::VERSION}.gem")
    epoch, _errors, status = Open3.capture3("git", "-C", root, "log", "-1", "--format=%ct")
    environment = status.success? ? { "SOURCE_DATE_EPOCH" => epoch.strip } : {}
    command(environment, RbConfig.ruby, "-S", "gem", "build", "net-connector.gemspec", "--output", artifact, chdir: root)
    artifact
  end

  def self.verify(artifact, root: Dir.pwd)
    root = File.expand_path(root)
    package = Gem::Package.new(File.expand_path(artifact))
    package.verify
    expected = Gem::Specification.load(File.join(root, "net-connector.gemspec"))
    raise "Cannot load net-connector.gemspec" unless expected
    unless METADATA.all? { |field| package.spec.public_send(field) == expected.public_send(field) }
      raise "Artifact metadata does not match the gemspec"
    end
    raise "Artifact file list differs from the source" unless package.contents.sort == expected.files.sort

    Dir.mktmpdir("net-connector-package-scan-") do |directory|
      File.open(artifact, "rb") do |io|
        Gem::Package::TarReader.new(io) do |archive|
          data = archive.find { |entry| entry.full_name == "data.tar.gz" }
          package.open_tar_gz(data) do |tar|
            tar.each do |entry|
              file = entry.full_name
              raise "Unexpected packaged file: #{file}" unless entry.file? && allowed_path?(file)

              source = File.join(root, file)
              raise "Source contains a symlink: #{file}" if File.symlink?(source)
              bytes = entry.read
              raise "Artifact differs from source: #{file}" unless bytes == File.binread(source)
              unless entry.header.mode & 0o111 == File.stat(source).mode & 0o111
                raise "Artifact executable permissions differ: #{file}"
              end
              target = File.join(directory, file)
              FileUtils.mkdir_p(File.dirname(target))
              File.binwrite(target, bytes)
            end
          end
        end
      end
      File.write(File.join(directory, "gem-metadata.rb"), package.spec.to_ruby)
      SecretScan.directory(directory, label: "package", report_root: root)
    end
    puts "Verified package: #{package.spec.full_name} (#{package.contents.size} files)"
    package.spec
  end

  def self.command(*arguments, **options)
    raise "Package verification command failed" unless system(*arguments, **options)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    Dir.chdir(BuildTools::ROOT) do
      artifact = ARGV.fetch(0) { PackageCheck.build }
      PackageCheck.verify(artifact)
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
