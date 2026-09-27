# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require_relative "inventory_budget"

module Net
  module Connector
    module Netdisco
      # 独立于 Rails 的 Netdisco 设备清单客户端；失败时不交付部分清单。
      class Client
        class Error < StandardError
          attr_reader :code

          def initialize(message = nil, code: :client_error)
            @code = code
            super(message)
          end
        end

        class QueryRequired < Error; end

        class InventoryTimeout < Error
          def initialize(_message = nil)
            super("Netdisco inventory exceeded inventory_timeout", code: :inventory_timeout)
          end
        end

        FIELDS = %w[ip name dns vendor os model os_ver serial].freeze
        DEFAULT_MAX_PAGES = 10_000
        DEFAULTS = { page_size: 500, max_pages: DEFAULT_MAX_PAGES, max_response_bytes: 16 * 1024 * 1024,
                     max_inventory_bytes: 128 * 1024 * 1024, max_devices: 100_000,
                     inventory_timeout: 300, allow_insecure_http: true }.freeze

        # 此纯校验入口也供 Settings 使用，避免配置预览与实际执行使用两套范围规则。
        def self.options(**values)
          raise ArgumentError, "unknown Netdisco client options" unless (values.keys - DEFAULTS.keys).empty?

          options = DEFAULTS.merge(values)
          %i[page_size max_pages max_response_bytes max_inventory_bytes max_devices].each do |name|
            value = options.fetch(name)
            raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
          end
          duration = options.fetch(:inventory_timeout)
          unless duration.is_a?(Numeric) && duration.real? && duration.finite? && duration.positive? && duration.to_f.finite?
            raise ArgumentError, "inventory_timeout must be a positive finite number"
          end
          unless [true, false].include?(options.fetch(:allow_insecure_http))
            raise ArgumentError, "allow_insecure_http must be true or false"
          end
          options.freeze
        end

        def self.validate_url!(url, allow_insecure_http: true)
          uri = URI.parse(url.to_s)
          unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
            raise ArgumentError, "url must be an HTTP(S) base URL without credentials, query or fragment"
          end
          if uri.scheme == "http" && !allow_insecure_http
            raise ArgumentError, "HTTP requires allow_insecure_http: true; use HTTPS"
          end
          uri
        rescue URI::InvalidURIError
          raise ArgumentError, "url is invalid", cause: nil
        end

        # requester 仍接收 (uri, request)，其自行阻塞的时间由注入方负责。
        def initialize(url:, username: nil, password: nil, api_key: nil, requester: nil, **options)
          @options = self.class.options(**options)
          @url = self.class.validate_url!(url, allow_insecure_http: @options.fetch(:allow_insecure_http)).freeze
          validate_credentials!(username, password, api_key)
          raise ArgumentError, "requester must respond to call" if requester && !requester.respond_to?(:call)

          @username, @password, @api_key = [username, password, api_key].map { |value| value&.dup&.freeze }
          @requester = requester
        end

        def devices
          budget = InventoryBudget.new(@options, clock: method(:monotonic))
          token = @api_key || authenticate(budget)
          rows = inventory(token, budget)
          budget.remaining
          rows
        end

        def inspect = "#<#{self.class} url=#{@url.scheme}://#{@url.host}>"

        private

        def inventory(token, budget)
          rows = []
          seen_ips = {}
          @options.fetch(:max_pages).times do |index|
            uri = endpoint("api/v1/search/device")
            uri.query = URI.encode_www_form(fields: FIELDS.join(","), limit: @options.fetch(:page_size),
                                            offset: index * @options.fetch(:page_size))
            page = request_json(uri, authorized_get(uri, token), budget, allow_empty: true, query_fallback: true)
            validate_rows!(page, budget)
            return rows.uniq if page.empty?

            if page.all? { |row| seen_ips[row.fetch("ip")] }
              raise Error.new("Netdisco pagination did not advance", code: :pagination_stalled), cause: nil
            end
            page.each { |row| seen_ips[row.fetch("ip")] = true }
            rows.concat(page)
          end
          raise Error.new("Netdisco inventory exceeded max_pages", code: :max_pages), cause: nil
        rescue QueryRequired
          query_required_devices(token, budget)
        end

        def query_required_devices(token, budget)
          uri = endpoint("api/v1/search/device")
          uri.query = URI.encode_www_form(q: "%", seeallcolumns: true)
          rows = request_json(uri, authorized_get(uri, token), budget, allow_empty: true)
          validate_rows!(rows, budget)
          rows.map { |row| row.slice(*FIELDS) }.uniq
        end

        def authenticate(budget)
          uri = endpoint("login")
          request = ::Net::HTTP::Post.new(uri)
          request.basic_auth(@username, @password)
          data = request_json(uri, request, budget)
          token = data["api_key"] if data.is_a?(Hash)
          raise Error, "Netdisco login did not return an API key" unless present?(token) && !token.match?(/[\r\n\x00]/)

          token
        end

        def authorized_get(uri, token)
          ::Net::HTTP::Get.new(uri).tap { |request| request["Authorization"] = "Apikey #{token}" }
        end

        def endpoint(path)
          @url.dup.tap { |uri| uri.path = "#{uri.path.chomp("/")}/#{path}" }
        end

        # 只保留稳定错误码及类型，不将服务正文、URI 或底层异常 cause 带进报告。
        def request_json(uri, request, budget, allow_empty: false, query_fallback: false)
          request["Accept"] = "application/json"
          budget.remaining
          response, body = request_body(uri, request, budget)
          if query_fallback && response.code == "400"
            parsed = JSON.parse(body)
            raise QueryRequired, "Netdisco requires a search query" if parsed.is_a?(Hash) && parsed["error"] == "Missing query"
          end
          unless response.is_a?(::Net::HTTPSuccess)
            status = response.code.to_s.match?(/\A\d{3}\z/) ? response.code : "invalid"
            raise Error.new("Netdisco request failed (HTTP #{status})", code: :request_failed), cause: nil
          end
          data = allow_empty && body.strip.empty? ? [] : JSON.parse(body)
          budget.remaining
          data
        rescue Error => error
          raise error, cause: nil
        rescue JSON::ParserError
          raise Error.new("Netdisco returned invalid JSON", code: :invalid_json), cause: nil
        rescue StandardError => error
          budget.remaining
          raise Error.new("Netdisco connection failed (#{error.class})", code: :connection_failed), cause: nil
        end

        def request_body(uri, request, budget)
          return default_request(uri, request, budget) unless @requester

          response = injected_request(uri, request, budget)
          budget.remaining
          body = response.body.to_s
          budget.consume_bytes(body.bytesize, response_bytes: 0)
          [response, body]
        end

        # 回调自己抛出的 Client::Error 也可能带正文，不能当成内部安全错误直接透传。
        def injected_request(uri, request, budget)
          @requester.call(uri, request)
        rescue StandardError => error
          budget.remaining
          raise Error.new("Netdisco connection failed (#{error.class})", code: :connection_failed), cause: nil
        end

        # 仅对自有 HTTP 传输施加总期限，覆盖响应头的持续慢速输入；不异步中断用户回调。
        # start 的块负责关闭连接；禁用隐式 GET 重试，所有阶段同时使用剩余的原生超时。
        def default_request(uri, request, budget)
          Timeout.timeout(budget.remaining, InventoryTimeout) do
            ::Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", max_retries: 0,
                              **http_timeouts(budget)) do |http|
              apply_timeouts(http, budget)
              with_http_deadline(http, budget) { read_response(http, request, budget) }
            end
          end
        end

        # 异步超时展开栈时，Net::HTTP 的 chunked ensure 可能再次等待读取。
        # 只关闭本次自有连接来解除这类阻塞；结束时唤醒并 join 观察线程，不遗留后台任务。
        def with_http_deadline(http, budget)
          mutex = Mutex.new
          changed = ConditionVariable.new
          finished = false
          timer = Thread.new do
            begin
              mutex.synchronize { changed.wait(mutex, budget.remaining) until finished }
            rescue InventoryTimeout
              begin
                http.finish
              rescue IOError, SystemCallError
                # 主请求可能已先关闭；外层 start 仍负责最终清理，保持原始预算错误。
                nil
              end
            end
          end
          yield
        ensure
          mutex&.synchronize { finished = true; changed.broadcast }
          timer&.join
        end

        def read_response(http, request, budget)
          body = "".b
          failure = nil
          response = http.request(request) do |reply|
            apply_timeouts(http, budget)
            reply.read_body do |chunk|
              budget.consume_bytes(chunk.bytesize, response_bytes: body.bytesize)
              body << chunk
              apply_timeouts(http, budget)
            rescue Error => error
              failure = error
              # Net::HTTP 的 chunked 收尾仍会读取分隔符；先关闭连接才能立即停止超额下载。
              http.finish
              raise
            end
          end
          budget.remaining
          [response, body]
        rescue StandardError => error
          raise failure || error, cause: nil
        end

        def http_timeouts(budget)
          remaining = budget.remaining
          { open_timeout: [10, remaining].min, read_timeout: [60, remaining].min, write_timeout: [10, remaining].min }
        end

        def apply_timeouts(http, budget)
          http_timeouts(budget).each { |name, value| http.public_send(:"#{name}=", value) }
        end

        def validate_rows!(rows, budget)
          unless rows.is_a?(Array)
            raise Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory), cause: nil
          end
          budget.consume_devices(rows.size)
          valid = rows.all? do |row|
            row.is_a?(Hash) && present?(row["ip"]) &&
              FIELDS.drop(1).all? { |field| row[field].nil? || row[field].is_a?(String) }
          end
          unless valid
            raise Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory), cause: nil
          end
        end

        def validate_credentials!(username, password, api_key)
          unless (api_key.nil? && present?(username) && present?(password)) ||
                 (present?(api_key) && username.nil? && password.nil?)
            raise ArgumentError, "provide either username and password or api_key"
          end
          if [username, password, api_key].compact.any? { |value| value.match?(/[\r\n\x00]/) }
            raise ArgumentError, "credentials must be single-line strings"
          end
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def present?(value) = value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
