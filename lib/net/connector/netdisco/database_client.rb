# frozen_string_literal: true

require "timeout"
require_relative "client"

module Net
  module Connector
    module Netdisco
      # SQL 负责业务选择和列别名；适配器只管理只读查询、清单预算与连接生命周期。
      class DatabaseClient
        CONNECTION_ENV = {
          host: "NETDISCO_DB_HOST", port: "NETDISCO_DB_PORT", dbname: "NETDISCO_DB_NAME",
          user: "NETDISCO_DB_USER", password: "NETDISCO_DB_PASS",
          sslmode: "NETDISCO_DB_SSLMODE", sslrootcert: "NETDISCO_DB_SSLROOTCERT",
          connect_timeout: "NETDISCO_DB_CONNECT_TIMEOUT"
        }.freeze
        REQUIRED_CONNECTION_KEYS = %i[host dbname user password].freeze
        DEFAULTS = Client::DEFAULTS.except(:allow_insecure_http).freeze

        def self.options(query:, query_params: [], **values)
          unless query.is_a?(String) && !query.strip.empty? && !query.include?("\0")
            raise ArgumentError, "query must be a nonempty SQL string without NUL"
          end
          unless query_params.is_a?(Array) && query_params.all? { |value|
            value.nil? || value == true || value == false || value.is_a?(Integer) ||
              (value.is_a?(Float) && value.finite?) || (value.is_a?(String) && !value.include?("\0"))
          }
            raise ArgumentError, "query_params must be an array of JSON scalar values without NUL"
          end
          raise ArgumentError, "unknown database inventory options" unless (values.keys - DEFAULTS.keys).empty?

          Client.options(**values).slice(*DEFAULTS.keys).merge(
            query: query.dup.freeze,
            query_params: query_params.map { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
          ).freeze
        end

        def initialize(connection_options:, **options)
          @options = self.class.options(**options)
          @connection_options = validate_connection_options!(connection_options)
        end

        # 每次查询独占连接和游标；只有全部结果验证成功后才把清单交给 Fleet。
        def devices
          require "pg"
          budget = InventoryBudget.new(@options, clock: method(:monotonic))
          connection = nil
          connected = false
          begin
            Timeout.timeout(budget.remaining, Client::InventoryTimeout) do
              # 先取得连接句柄再交付超时，确保异常到达时 ensure 能显式关闭连接。
              Thread.handle_interrupt(Client::InventoryTimeout => :never) do
                connection = PG::Connection.connect_start(@connection_options)
              end
              # PostgreSQL NOTICE 可能包含 SQL 或数据，不交给 libpq 默认的 stderr 输出器。
              connection.set_notice_processor { |_notice| nil }
              wait_for_connection(connection, budget)
              connected = true
              # 使用 pg 可中断的 Ruby 等待接口；底层 socket 仍以非阻塞方式工作。
              connection.setnonblocking(false)
              connection.set_client_encoding("UTF8")
              connection.exec("BEGIN READ ONLY").clear
              set_statement_timeout(connection, budget)
              # 即使没有参数也走扩展查询协议，由 PostgreSQL 拒绝多语句和非查询命令。
              connection.exec_params("DECLARE net_connector_inventory NO SCROLL CURSOR FOR\n#{@options.fetch(:query)}",
                                     @options.fetch(:query_params)).clear
              rows = inventory(connection, budget)
              connection.exec("ROLLBACK").clear
              budget.remaining
              rows
            end
          rescue Client::Error => error
            raise error, cause: nil
          rescue PG::QueryCanceled
            raise Client::InventoryTimeout, cause: nil
          rescue PG::Error, IOError, SystemCallError
            code = connected ? :query_failed : :connection_failed
            raise Client::Error.new("Netdisco database #{code.to_s.tr("_", " ")}", code: code), cause: nil
          ensure
            connection&.finish
          end
        end

        def inspect = "#<#{self.class}>"

        private

        def wait_for_connection(connection, budget)
          deadline = monotonic + @connection_options.fetch(:connect_timeout, budget.remaining).to_f
          loop do
            status = connection.connect_poll
            return if status == PG::PGRES_POLLING_OK
            raise PG::ConnectionBad unless [PG::PGRES_POLLING_READING, PG::PGRES_POLLING_WRITING].include?(status)

            remaining = [budget.remaining, deadline - monotonic].min
            raise PG::ConnectionBad if remaining <= 0

            socket = connection.socket_io
            readers = status == PG::PGRES_POLLING_READING ? [socket] : nil
            writers = status == PG::PGRES_POLLING_WRITING ? [socket] : nil
            next if IO.select(readers, writers, [socket], remaining)

            budget.remaining
            raise PG::ConnectionBad
          end
        end

        def validate_connection_options!(options)
          unless options.is_a?(Hash) && (options.keys - CONNECTION_ENV.keys).empty?
            raise ArgumentError, "connection_options must contain supported PostgreSQL connection keys"
          end
          REQUIRED_CONNECTION_KEYS.each do |key|
            value = options[key]
            unless value.is_a?(String) && !value.strip.empty?
              raise ArgumentError, "#{CONNECTION_ENV.fetch(key)} is required"
            end
          end
          options.each do |key, value|
            valid = value.is_a?(String) && !value.empty? && !value.include?("\0")
            valid ||= %i[port connect_timeout].include?(key) && value.is_a?(Integer)
            raise ArgumentError, "#{CONNECTION_ENV.fetch(key)} is invalid" unless valid
          end
          %i[port connect_timeout].each do |key|
            next unless options.key?(key)

            value = options.fetch(key).to_s
            maximum = key == :port ? 65_535 : 2_147_483_647
            unless value.match?(/\A\d+\z/) && value.to_i.between?(1, maximum)
              raise ArgumentError, "#{CONNECTION_ENV.fetch(key)} must be a positive integer within range"
            end
          end
          if options[:sslmode] && !%w[disable allow prefer require verify-ca verify-full].include?(options[:sslmode])
            raise ArgumentError, "NETDISCO_DB_SSLMODE is invalid"
          end
          # libpq 会把 dbname 中的 URI/conninfo 再解释为连接参数，不能借此绕过凭据来源。
          if options.fetch(:dbname).match?(/=|\Apostgres(?:ql)?:\/\//)
            raise ArgumentError, "NETDISCO_DB_NAME must be a database name, not a connection string"
          end
          options.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
        end

        def set_statement_timeout(connection, budget)
          milliseconds = [(budget.remaining * 1000).ceil, 2_147_483_647].min
          connection.exec_params("SELECT set_config('statement_timeout', $1, true)", [milliseconds.to_s]).clear
        end

        def inventory(connection, budget)
          rows = []
          @options.fetch(:max_pages).times do
            set_statement_timeout(connection, budget)
            count = fetch_page(connection, rows, budget)
            return rows if count < @options.fetch(:page_size)
          end
          raise Client::Error.new("Netdisco inventory exceeded max_pages", code: :max_pages), cause: nil
        end

        # 单行模式避免 libpq 先缓存整页；Ruby 只积累已经通过预算检查的白名单字段。
        def fetch_page(connection, rows, budget)
          connection.send_query_params("FETCH FORWARD #{@options.fetch(:page_size)} FROM net_connector_inventory", [])
          connection.set_single_row_mode
          count = 0
          response_bytes = 0
          while (result = connection.get_result)
            begin
              result.check
              response_bytes = append_rows(result, rows, budget, response_bytes)
              count += result.ntuples
            ensure
              result.clear
            end
          end
          count
        end

        def append_rows(result, rows, budget, response_bytes)
          fields = result.fields
          unless fields.include?("ip") && fields.uniq == fields
            raise Client::Error.new("Netdisco database query must return unique column names including ip",
                                    code: :invalid_inventory), cause: nil
          end
          budget.consume_devices(result.ntuples)
          result.each do |row|
            # 未选用的列也占传输预算，但不会进入清单、计划或报告。
            size = row.sum { |key, value| key.bytesize + (value&.bytesize || 0) }
            budget.consume_bytes(size, response_bytes: response_bytes)
            response_bytes += size
            unless row["ip"].is_a?(String) && !row["ip"].strip.empty?
              raise Client::Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory), cause: nil
            end
            rows << row.slice(*Client::FIELDS)
          end
          response_bytes
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
