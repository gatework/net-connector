# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "rbconfig"
require "rubygems/package"
require "stringio"

# 固定上游版本及归档摘要，Linux/macOS 使用同一套工具；只提取指定的可执行文件。
module BuildTools
  ROOT = File.expand_path("..", __dir__)
  TOOLS = {
    "gitleaks" => {
      repository: "gitleaks/gitleaks", version: "8.30.1", amd64: "x64",
      checksums: {
        "darwin_arm64" => "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
        "darwin_x64" => "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709",
        "linux_arm64" => "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080",
        "linux_x64" => "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
      }
    },
    "actionlint" => {
      repository: "rhysd/actionlint", version: "1.7.12", amd64: "amd64",
      checksums: {
        "darwin_arm64" => "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
        "darwin_amd64" => "5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644",
        "linux_arm64" => "325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
        "linux_amd64" => "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
      }
    }
  }.freeze

  def self.path(name)
    tool = TOOLS.fetch(name)
    os = RbConfig::CONFIG.fetch("host_os")
    os = os.include?("darwin") ? "darwin" : (os.include?("linux") ? "linux" : os)
    cpu = RbConfig::CONFIG.fetch("host_cpu")
    cpu = %w[arm64 aarch64].include?(cpu) ? "arm64" : (%w[x86_64 amd64].include?(cpu) ? tool[:amd64] : cpu)
    platform = "#{os}_#{cpu}"
    checksum = tool.fetch(:checksums).fetch(platform) { raise "Unsupported build-tool platform: #{platform}" }
    directory = File.join(ROOT, "tmp", "tools", "#{name}-#{tool[:version]}", platform)
    FileUtils.mkdir_p(directory)
    archive = File.join(directory, "archive.tar.gz")
    executable = File.join(directory, name)
    File.open(File.join(directory, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      bytes = File.file?(archive) ? File.binread(archive) : download(
        "https://github.com/#{tool[:repository]}/releases/download/v#{tool[:version]}/#{name}_#{tool[:version]}_#{platform}.tar.gz"
      )
      raise "#{name} archive checksum mismatch" unless Digest::SHA256.hexdigest(bytes) == checksum

      File.binwrite(archive, bytes)
      binary = nil
      Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each { |entry| binary = entry.read if entry.file? && entry.full_name == name }
        end
      end
      raise "#{name} is missing from its archive" unless binary

      unless File.file?(executable) && File.binread(executable) == binary
        File.binwrite("#{executable}.new", binary)
        File.chmod(0o755, "#{executable}.new")
        File.rename("#{executable}.new", executable)
      end
    end
    executable
  end

  def self.download(url, remaining: 5)
    uri = URI(url)
    raise "Tool download requires HTTPS" unless uri.scheme == "https"
    raise "Too many tool download redirects" if remaining.negative?

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
      http.get(uri.request_uri, "User-Agent" => "net-connector-build")
    end
    return response.body if response.is_a?(Net::HTTPSuccess)
    return download(URI.join(url, response.fetch("location")).to_s, remaining: remaining - 1) if response.is_a?(Net::HTTPRedirection)

    raise "Tool download failed: HTTP #{response.code}"
  end
end
