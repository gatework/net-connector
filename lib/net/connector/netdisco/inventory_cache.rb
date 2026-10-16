# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require_relative "client"
require_relative "../engine/error_metadata"
require_relative "../storage/private_file"

module Net
  module Connector
    module Netdisco
      # 只缓存完整的原始清单；规则映射和设备凭据始终留在每次执行入口。
      class InventoryCache
        class Error < IOError; end
        class Busy < Error; end
        class InvalidCache < StandardError; end
        private_constant :InvalidCache

        DEFAULT_TTL = 3 * 24 * 60 * 60
        ERROR_CODES = %i[client_error inventory_timeout request_failed invalid_json connection_failed
                         pagination_stalled max_pages max_response_bytes max_inventory_bytes max_devices
                         invalid_inventory query_failed].freeze
        private_constant :ERROR_CODES
        attr_reader :status, :refresh_error_code, :write_error_type, :fetched_at

        def initialize(client:, directory:, identity:, ttl: DEFAULT_TTL,
                       max_inventory_bytes: Client::DEFAULTS.fetch(:max_inventory_bytes),
                       max_devices: Client::DEFAULTS.fetch(:max_devices), clock: -> { Time.now.utc }, lock_timeout: 5)
          raise ArgumentError, "client must respond to devices" unless client.respond_to?(:devices)
          raise ArgumentError, "directory must be a nonempty String" unless directory.is_a?(String) && !directory.empty? && !directory.include?("\0")
          raise ArgumentError, "identity must be a nonempty String" unless identity.is_a?(String) && !identity.empty?
          [ttl, lock_timeout].each do |value|
            unless value.is_a?(Numeric) && value.real? && value.finite? && value >= 0 && value.to_f.finite?
              raise ArgumentError, "cache durations must be nonnegative finite numbers"
            end
          end
          [max_inventory_bytes, max_devices].each do |value|
            raise ArgumentError, "cache limits must be positive integers" unless value.is_a?(Integer) && value.positive?
          end
          raise ArgumentError, "clock must respond to call" unless clock.respond_to?(:call)

          @client, @directory, @clock = client, File.expand_path(directory).freeze, clock
          @identity = Digest::SHA256.hexdigest(identity).freeze
          @ttl, @lock_timeout = ttl, lock_timeout
          @max_inventory_bytes, @max_devices = max_inventory_bytes, max_devices
          @path = File.join(@directory, "#{@identity}.json").freeze
          @lock_path = File.join(@directory, "#{@identity}.lock").freeze
        end

        # 锁内重读避免多个进程同时刷新；强刷仍然允许远端失败时交付历史清单。
        def devices(force_refresh: false)
          raise ArgumentError, "force_refresh must be true or false" unless [true, false].include?(force_refresh)

          @status = @refresh_error_code = @write_error_type = @fetched_at = nil
          with_directory do
            previous = read_cache
            return deliver(previous, :fresh_cache) if !force_refresh && fresh?(previous)

            with_lock do
              previous = read_cache
              return deliver(previous, :fresh_cache) if !force_refresh && fresh?(previous)

              refresh(previous)
            end
          end
        end

        def inspect = "#<#{self.class} status=#{@status.inspect}>"

        private

        # 目录的所有者和权限是末级 NOFOLLOW 检查的前提；不修补不可信的既有目录。
        def with_directory
          FileUtils.mkdir_p(@directory, mode: 0o700) unless File.exist?(@directory) || File.symlink?(@directory)
          File.open(@directory, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |directory|
            stat = directory.stat
            unless stat.directory? && stat.uid == Process.euid && (stat.mode & 0o7777) == 0o700
              raise Error, "inventory cache directory must be owned with mode 0700"
            end
            verify_entry!(@directory, stat)
            result = yield
            verify_entry!(@directory, stat)
            result
          end
        rescue Errno::ELOOP, Errno::ENOTDIR
          raise Error, "inventory cache directory must not be a symlink", cause: nil
        end

        def with_lock
          File.open(@lock_path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600) do |lock|
            verify_private_file!(lock, @lock_path)
            deadline = monotonic + @lock_timeout
            until lock.flock(File::LOCK_EX | File::LOCK_NB)
              remaining = deadline - monotonic
              raise Busy, "inventory cache refresh lock timed out" if remaining <= 0

              sleep([remaining, 0.05].min)
            end
            verify_private_file!(lock, @lock_path)
            yield
          end
        rescue Errno::ELOOP, Errno::EISDIR, Errno::ENXIO
          raise Error, "inventory cache lock must be a private regular file", cause: nil
        end

        # 同一 FD 上校验和限量读取，不依赖 stat 的大小来约束持续增长的文件。
        def read_cache
          File.open(@path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
            stat = verify_private_file!(file, @path)
            return nil if stat.size > @max_inventory_bytes

            body = file.read(@max_inventory_bytes + 1)
            return nil if body.nil? || body.bytesize > @max_inventory_bytes

            entry = JSON.parse(body)
            unless entry.is_a?(Hash) && entry.keys.sort == %w[fetched_at identity rows schema] &&
                   entry["schema"] == 1 && entry["identity"] == @identity && valid_time?(entry["fetched_at"])
              return nil
            end
            entry["rows"] = normalize_rows(entry["rows"])
            entry
          end
        rescue Errno::ENOENT, JSON::ParserError, InvalidCache
          nil
        rescue Errno::ELOOP, Errno::EISDIR, Errno::ENXIO
          raise Error, "inventory cache must be a private regular file", cause: nil
        end

        # 清单已取得后，落盘失败不能让调用方退回旧清单或重新执行远端查询。
        def refresh(previous)
          begin
            rows = normalize_rows(@client.devices)
          rescue Client::Error => error
            raise unless previous

            @refresh_error_code = ERROR_CODES.include?(error.code) ? error.code : :client_error
            return deliver(previous, :stale_cache)
          rescue InvalidCache
            error = Client::Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory)
            raise error, cause: nil unless previous

            @refresh_error_code = ERROR_CODES.include?(error.code) ? error.code : :client_error
            return deliver(previous, :stale_cache)
          end
          entry = { "schema" => 1, "identity" => @identity, "fetched_at" => now, "rows" => rows }
          begin
            body = JSON.generate(entry)
            raise Error, "inventory cache exceeds max_inventory_bytes" if body.bytesize > @max_inventory_bytes

            Storage::PrivateFile.write(@path, body)
          rescue StandardError => error
            @write_error_type = ErrorMetadata.type(error.class.name) || "StandardError"
          end
          deliver(entry, :refreshed)
        end

        # 校验限额后只复制白名单字段；调用方和缓存不能共享可变的远端响应。
        def normalize_rows(rows)
          raise InvalidCache unless rows.is_a?(Array) && rows.size <= @max_devices

          bytes = 0
          rows.map do |row|
            unless row.is_a?(Hash) && row["ip"].is_a?(String) && !row["ip"].strip.empty?
              raise InvalidCache
            end
            # 一次遍历完成白名单、限额与复制，避免中间 Hash 和逐字段求和产生的数组。
            Client::FIELDS.each_with_object({}) do |field, selected|
              next unless row.key?(field)

              value = row[field]
              raise InvalidCache unless value.nil? || value.is_a?(String)

              bytes += field.bytesize + (value&.bytesize || 0)
              raise InvalidCache if bytes > @max_inventory_bytes

              selected[field] = value&.dup&.freeze
            end.freeze
          end.freeze
        end

        def verify_private_file!(file, path)
          stat = file.stat
          unless stat.file? && stat.uid == Process.euid && stat.nlink == 1 && (stat.mode & 0o7777) == 0o600
            raise Error, "inventory cache files must be owned regular files with mode 0600 and one link"
          end
          verify_entry!(path, stat)
          stat
        end

        def verify_entry!(path, stat)
          current = File.lstat(path)
          return if current.dev == stat.dev && current.ino == stat.ino && !current.symlink?

          raise Error, "inventory cache path changed during access"
        end

        def valid_time?(value)
          value.is_a?(Numeric) && value.real? && value.finite? && value >= 0 && value <= now
        end

        def fresh?(entry) = entry && now - entry.fetch("fetched_at") < @ttl

        def deliver(entry, status)
          @status = status
          @fetched_at = Time.at(entry.fetch("fetched_at")).utc.freeze
          entry.fetch("rows")
        end

        def now
          input = @clock.call
          value = input.is_a?(Time) ? input.to_f : input
          unless value.is_a?(Numeric) && value.real? && value.finite? && value >= 0 && value.to_f.finite?
            raise ArgumentError, "clock must return a finite nonnegative timestamp"
          end

          value.to_f
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
