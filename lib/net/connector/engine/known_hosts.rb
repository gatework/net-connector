# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "open3"
require_relative "errors"

module Net
  module Connector
    # SSH 只写会话副本；认证后在跨进程锁内合并，网络等待不占用共享文件锁。
    class KnownHosts
      attr_reader :path

      def initialize(configuration, replace: false)
        destination = configuration.known_hosts || File.join(Dir.home, ".ssh", "known_hosts")
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        @destination = File.join(File.realpath(File.dirname(destination)), File.basename(destination))
        @host = configuration.host
        @host = "[#{@host}]:#{configuration.port}" if configuration.port && configuration.port != 22
        @replace = replace
        @original = read_shared
        @file = Tempfile.new([".nc-known-hosts-", ""], File.dirname(@destination))
        @path = @file.path
        @file.write(@original)
        @file.flush
        remove_host(@path) if @replace
      rescue Exception # rubocop:disable Lint/RescueException -- Remove the private snapshot on interruption.
        close
        raise
      end

      def commit
        additions = File.binread(path).lines - @original.lines
        return if additions.empty?

        with_lock do
          current = read_shared
          Tempfile.create([".nc-known-hosts-merge-", ""], File.dirname(@destination)) do |file|
            file.write(current)
            file.flush
            reject_changed_key!(file.path) unless @replace
            remove_host(file.path) if @replace
            contents = File.binread(file.path)
            entries = contents.lines
            additions.each { |line| entries << line unless entries.include?(line) }
            File.open(file.path, "wb", 0o600) do |replacement|
              replacement.write(entries.map { |line| line.end_with?("\n") ? line : line + "\n" }.join)
              replacement.flush
              replacement.fsync
            end
            File.rename(file.path, @destination)
          ensure
            File.unlink(file.path + ".old") if file && File.exist?(file.path + ".old")
          end
        end
      end

      def close
        File.unlink(@path + ".old") if @path && File.exist?(@path + ".old")
        @file&.close!
        @file = nil
      end

      private

      def read_shared
        File.open(@destination, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          raise IOError, "known_hosts must be a regular file" unless file.stat.file?

          file.read
        end
      rescue Errno::ENOENT
        ""
      end

      def reject_changed_key!(current_path)
        current = host_keys(current_path)
        staged = host_keys(path)
        return if current.empty? || (staged - current).empty?

        raise ConnectionError.new("host key changed during concurrent registration", code: :host_key_changed)
      end

      def host_keys(path)
        output, status = Open3.capture2e("ssh-keygen", "-f", path, "-F", @host)
        raise IOError, "reading device host key failed" unless [0, 1].include?(status.exitstatus)

        output.lines.reject { |line| line.start_with?("#") }.map { |line| line.split[1, 2] }.uniq
      end

      def remove_host(path)
        _output, status = Open3.capture2e("ssh-keygen", "-f", path, "-R", @host)
        raise IOError, "removing device host key failed" unless status.success?
      end

      def with_lock
        lock_path = @destination + ".nc-lock"
        File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600) do |file|
          stat = file.stat
          unless stat.file? && stat.uid == Process.euid && stat.nlink == 1 && (stat.mode & 0o7777) == 0o600
            raise IOError, "known_hosts lock must be an owned private regular file"
          end
          file.flock(File::LOCK_EX)
          current = File.lstat(lock_path)
          raise IOError, "known_hosts lock changed" unless current.dev == stat.dev && current.ino == stat.ino

          yield
        end
      end
    end
  end
end
