# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require_relative "budget"
require_relative "../../parallel/observer"

module Net
  module Connector
    module Netdisco
      module Inventory
        # 通过 HTTP API 读取 Netdisco 设备清单；失败时不交付部分清单。
        class HTTP
          class QueryRequired < Inventory::Error; end
          private_constant :QueryRequired

          DEFAULTS = Inventory::DEFAULTS.merge(allow_insecure_http: true).freeze
          OPTIONAL_FIELDS = FIELDS.drop(1).freeze
          private_constant :OPTIONAL_FIELDS

          # 校验 HTTP 专用选项与共享清单资源上限，返回不可变策略。
          def self.options(**values)
            raise ArgumentError, "unknown HTTP inventory options" unless (values.keys - DEFAULTS.keys).empty?

            allow_insecure_http = values.fetch(:allow_insecure_http, DEFAULTS.fetch(:allow_insecure_http))
            raise ArgumentError, "allow_insecure_http must be true or false" unless [true, false].include?(allow_insecure_http)

            Inventory.options(**values.except(:allow_insecure_http)).merge(allow_insecure_http: allow_insecure_http).freeze
          end

          # 只接受无凭据、查询和片段的 HTTP(S) 基地址，并执行明文传输策略。
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

          # 在同一次预算和连接作用域内认证、分页并交付完整清单。
          def devices
            budget = Inventory::Budget.new(@options, clock: method(:monotonic))
            with_connection(budget) do |http|
              token = @api_key || authenticate(budget, http)
              rows = inventory(token, budget, http)
              budget.remaining
              rows
            end
          end

          # 返回对象的安全摘要，不展开正文或认证凭据。
          def inspect = "#<#{self.class} url=#{@url.scheme}://#{@url.host}>"

          private

          # 按页累积清单并检查分页是否前进，遇兼容响应时改用查询接口。
          # 分页和兼容查询共享一个总预算；只有完整且有效的清单才能交给规划器。
          def inventory(token, budget, http)
            rows = []
            seen_ips = {}
            @options.fetch(:max_pages).times do |index|
              uri = endpoint("api/v1/search/device")
              uri.query = URI.encode_www_form(fields: FIELDS.join(","), limit: @options.fetch(:page_size),
                                              offset: index * @options.fetch(:page_size))
              page = request_json(uri, authorized_get(uri, token), budget, http, allow_empty: true, query_fallback: true)
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
            query_required_devices(token, budget, http)
          end

          # 调用需要查询参数的兼容接口，验证完整响应后只保留清单字段。
          def query_required_devices(token, budget, http)
            uri = endpoint("api/v1/search/device")
            uri.query = URI.encode_www_form(q: "%", seeallcolumns: true)
            rows = request_json(uri, authorized_get(uri, token), budget, http, allow_empty: true)
            validate_rows!(rows, budget)
            rows.map { |row| row.slice(*FIELDS) }.uniq
          end

          # 以基本认证取得 API key，拒绝缺失或含换行的令牌。
          def authenticate(budget, http)
            uri = endpoint("login")
            request = ::Net::HTTP::Post.new(uri)
            request.basic_auth(@username, @password)
            data = request_json(uri, request, budget, http)
            token = data["api_key"] if data.is_a?(Hash)
            raise Error, "Netdisco login did not return an API key" unless present?(token) && !token.match?(/[\r\n\x00]/)

            token
          end

          # 构造携带 API key 请求头的清单读取请求。
          def authorized_get(uri, token)
            ::Net::HTTP::Get.new(uri).tap { |request| request["Authorization"] = "Apikey #{token}" }
          end

          # 在固定基地址下组合接口路径，不接受外部任意端点。
          def endpoint(path)
            @url.dup.tap { |uri| uri.path = "#{uri.path.chomp("/")}/#{path}" }
          end

          # 只保留稳定错误码及类型，不将服务正文、URI 或底层异常 cause 带进报告。
          def request_json(uri, request, budget, http, allow_empty: false, query_fallback: false)
            request["Accept"] = "application/json"
            budget.remaining
            response, body = request_body(uri, request, budget, http)
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

          # 使用注入请求器或当前 HTTP 连接读取正文，并执行同一清单预算。
          def request_body(uri, request, budget, http)
            unless @requester
              apply_timeouts(http, budget)
              return read_response(http, request, budget)
            end

            response = injected_request(uri, request, budget)
            budget.remaining
            body = response.body.to_s
            budget.consume_bytes(body.bytesize, response_bytes: 0)
            [response, body]
          end

          # 回调自己抛出的 Inventory::Error 也可能带正文，不能当成内部安全错误直接透传。
          def injected_request(uri, request, budget)
            @requester.call(uri, request)
          rescue StandardError => error
            budget.remaining
            raise Error.new("Netdisco connection failed (#{error.class})", code: :connection_failed), cause: nil
          end

          # 仅对自有 HTTP 传输施加总期限，覆盖响应头的持续慢速输入；不异步中断用户回调。
          # 一次调用独占连接与观察器，认证和分页共享预算；不把连接存入实例供并发调用共用。
          # start 的块负责关闭连接；禁用隐式 GET 重试，服务端主动断开时允许新请求正常重连。
          def with_connection(budget)
            return yield nil if @requester

            ::Timeout.timeout(budget.remaining, Inventory::Timeout) do
              ::Net::HTTP.start(@url.host, @url.port, use_ssl: @url.scheme == "https", max_retries: 0,
                                **http_timeouts(budget)) do |http|
                with_http_deadline(http, budget) { yield http }
              end
            end
          rescue Inventory::Error => error
            raise error, cause: nil
          rescue StandardError => error
            budget.remaining
            raise Inventory::Error.new("Netdisco connection failed (#{error.class})", code: :connection_failed), cause: nil
          end

          # 异步超时展开栈时，Net::HTTP 的 chunked ensure 可能再次等待读取。
          # 只关闭本次自有连接来解除这类阻塞；结束时唤醒并 join 观察线程，不遗留后台任务。
          def with_http_deadline(http, budget, &)
            mutex = Mutex.new
            changed = ConditionVariable.new
            finished = false
            task = lambda do
              begin
                mutex.synchronize { changed.wait(mutex, budget.remaining) until finished }
              rescue Inventory::Timeout
                begin
                  http.finish
                rescue IOError, SystemCallError
                  # 主请求可能已先关闭；外层 start 仍负责最终清理，保持原始预算错误。
                  nil
                end
              end
            end
            stop = -> { mutex.synchronize { finished = true; changed.broadcast } }
            Parallel::Observer.run(task: task, stop: stop, &)
          end

          # 逐块检查正文预算并积累字节；超限时关闭自有连接，避免继续下载。
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

          # 按总预算剩余时间收紧连接、读取和写入超时。
          def http_timeouts(budget)
            remaining = budget.remaining
            { open_timeout: [10, remaining].min, read_timeout: [60, remaining].min, write_timeout: [10, remaining].min }
          end

          # 将当前预算推导的超时同步到自有 HTTP 连接。
          def apply_timeouts(http, budget)
            http_timeouts(budget).each { |name, value| http.public_send(:"#{name}=", value) }
          end

          # 校验清单行及可选字段，同时将原始记录数计入总预算。
          def validate_rows!(rows, budget)
            unless rows.is_a?(Array)
              raise Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory), cause: nil
            end
            budget.consume_devices(rows.size)
            valid = rows.all? do |row|
              row.is_a?(Hash) && present?(row["ip"]) &&
                OPTIONAL_FIELDS.all? { |field| row[field].nil? || row[field].is_a?(String) }
            end
            return if valid

            raise Error.new("Netdisco returned an invalid device inventory", code: :invalid_inventory), cause: nil
          end

          # 要求用户名密码与 API key 二选一，并拒绝凭据中的控制分隔符。
          def validate_credentials!(username, password, api_key)
            unless (api_key.nil? && present?(username) && present?(password)) ||
                   (present?(api_key) && username.nil? && password.nil?)
              raise ArgumentError, "provide either username and password or api_key"
            end
            return unless [username, password, api_key].compact.any? { |value| value.match?(/[\r\n\x00]/) }

            raise ArgumentError, "credentials must be single-line strings"
          end

          # 读取单调时钟秒数，避免系统校时影响期限与耗时计算。
          def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # 判断输入是否为包含非空白内容的字符串。
          def present?(value) = value.is_a?(String) && !value.strip.empty?
        end
      end
    end
  end
end
