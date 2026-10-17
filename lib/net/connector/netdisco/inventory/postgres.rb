# frozen_string_literal: true

require "timeout"
require_relative "../inventory"
require_relative "budget"

module Net
  module Connector
    module Netdisco
      module Inventory
        # SQL 负责业务选择和列别名；适配器只管理只读查询、清单预算与连接生命周期。
        class Postgres
          # 只有数据库身份从环境读取；非敏感连接策略的内部选项与诊断名称另行映射。
          CONNECTION_ENV = {
            host: "ND_DB_HOST", dbname: "ND_DB_NAME", user: "ND_DB_USER", password: "ND_DB_PASS"
          }.freeze
          CONNECTION_OPTIONS = CONNECTION_ENV.merge(
            port: "netdisco.db_port", sslmode: "netdisco.db_sslmode", sslrootcert: "netdisco.db_sslrootcert",
            connect_timeout: "netdisco.db_connect_timeout"
          ).freeze
          REQUIRED_CONNECTION_KEYS = %i[host dbname user password].freeze
          POLICY_KEYS = (CONNECTION_OPTIONS.keys - REQUIRED_CONNECTION_KEYS).freeze
          private_constant :POLICY_KEYS
          DEFAULTS = Inventory::DEFAULTS

          # 预检与实际连接共用公开策略校验；不读取身份凭据，也不访问文件或数据库。
          def self.connection_policy(**options)
            raise ArgumentError, "unknown PostgreSQL connection policy" unless (options.keys - POLICY_KEYS).empty?

            options.each do |key, value|
              valid = value.is_a?(String) && !value.empty? && !value.include?("\0")
              valid ||= %i[port connect_timeout].include?(key) && value.is_a?(Integer)
              raise ArgumentError, "#{CONNECTION_OPTIONS.fetch(key)} is invalid" unless valid
            end
            %i[port connect_timeout].each do |key|
              next unless options.key?(key)

              value = options.fetch(key).to_s
              maximum = key == :port ? 65_535 : 2_147_483_647
              unless value.match?(/\A\d+\z/) && value.to_i.between?(1, maximum)
                raise ArgumentError, "#{CONNECTION_OPTIONS.fetch(key)} must be a positive integer within range"
              end
            end
            if options[:sslmode] && !%w[disable allow prefer require verify-ca verify-full].include?(options[:sslmode])
              raise ArgumentError, "netdisco.db_sslmode is invalid"
            end
            options.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
          end

          # 纯校验 SQL、绑定参数和清单预算，不连接数据库或打印查询内容。
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

            Inventory.options(**values).merge(
              query: query.dup.freeze,
              query_params: query_params.map { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
            ).freeze
          end

          # 复制并校验查询与连接选项；真正连接由 devices 的资源作用域管理。
          def initialize(connection_options:, **options)
            @options = self.class.options(**options)
            @connection_options = validate_connection_options!(connection_options)
          end

          # 每次查询独占连接和游标；只有全部结果验证成功后才把清单交给 Fleet。
          def devices
            require "pg"
            budget = Inventory::Budget.new(@options, clock: method(:monotonic))
            connection = nil
            connected = false
            failed = false
            begin
              ::Timeout.timeout(budget.remaining, Inventory::Timeout) do
                # 只在取得句柄并登记所有权期间延后异步异常，离开后仍立即传播原中断。
                Thread.handle_interrupt(Exception => :never) do
                  connection = PG::Connection.connect_start(@connection_options)
                end
                # PostgreSQL NOTICE 可能包含 SQL 或数据，不交给 libpq 默认的 stderr 输出器。
                connection.set_notice_processor { |_notice| nil }
                wait_for_connection(connection, budget)
                connected = true
                query_inventory(connection, budget)
              end
            rescue Inventory::Error => error
              failed = true
              raise error, cause: nil
            rescue PG::QueryCanceled
              failed = true
              raise Inventory::Timeout, cause: nil
            rescue PG::Error, IOError, SystemCallError
              failed = true
              code = connected ? :query_failed : :connection_failed
              raise Inventory::Error.new("Netdisco database #{code.to_s.tr("_", " ")}", code: code), cause: nil
            rescue Exception # rubocop:disable Lint/RescueException -- 清理继续保留未知异常和用户中断。
              failed = true
              raise
            ensure
              close_connection(connection, failed: failed)
            end
          end

          def inspect = "#<#{self.class}>"

          private

          # 连接始终尝试关闭；收尾故障不能覆盖查询失败或中断，完成后的关闭失败仍须传播。
          def close_connection(connection, failed:)
            connection&.finish
          rescue Exception # rubocop:disable Lint/RescueException -- 保留先发生的查询失败和用户中断。
            raise unless failed
          end

          # 使用 pg 可中断的等待与扩展查询协议，只读游标共享本次清单的总预算。
          def query_inventory(connection, budget)
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

          # 数据库名不得嵌入 URI/conninfo；合法选项仍受清单总期限及只读查询边界约束。
          def validate_connection_options!(options)
            unless options.is_a?(Hash) && (options.keys - CONNECTION_OPTIONS.keys).empty?
              raise ArgumentError, "connection_options must contain supported PostgreSQL connection keys"
            end
            REQUIRED_CONNECTION_KEYS.each do |key|
              value = options[key]
              unless value.is_a?(String) && !value.strip.empty?
                raise ArgumentError, "#{CONNECTION_OPTIONS.fetch(key)} is required"
              end
              raise ArgumentError, "#{CONNECTION_OPTIONS.fetch(key)} is invalid" if value.include?("\0")
            end
            self.class.connection_policy(**options.slice(*POLICY_KEYS))
            # libpq 会把 dbname 中的 URI/conninfo 再解释为连接参数，不能借此绕过凭据来源。
            if options.fetch(:dbname).match?(/=|\Apostgres(?:ql)?:\/\//)
              raise ArgumentError, "ND_DB_NAME must be a database name, not a connection string"
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
            raise Inventory::Error.new("Netdisco inventory exceeded max_pages", code: :max_pages), cause: nil
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
              raise Inventory::Error.new("Netdisco database query must return unique column names including ip",
                                      code: :invalid_inventory), cause: nil
            end
            budget.consume_devices(result.ntuples)
            result.each do |row|
              # 未选用的列也占传输预算，但不会进入清单、计划或报告。
              size = row.sum { |key, value| key.bytesize + (value&.bytesize || 0) }
              budget.consume_bytes(size, response_bytes: response_bytes)
              response_bytes += size
              unless row["ip"].is_a?(String) && !row["ip"].strip.empty?
                raise Inventory::Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory), cause: nil
              end
              rows << row.slice(*Inventory::FIELDS)
            end
            response_bytes
          end

          def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
