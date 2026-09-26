# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Net
  module Connector
    module Netdisco
      # 独立于 Rails 的 Netdisco 设备清单客户端。
      class Client
        class Error < StandardError; end

        class QueryRequired < Error; end

        FIELDS = %w[ip name dns vendor os model os_ver serial].freeze
        DEFAULT_MAX_PAGES = 10_000

        # 校验 Netdisco 地址与凭据并建立请求入口。
        def initialize(url:, username: nil, password: nil, api_key: nil, page_size: 500,
                       max_pages: DEFAULT_MAX_PAGES, requester: nil)
          @url = URI.parse(url.to_s)
          unless @url.is_a?(URI::HTTP) && @url.host && !@url.userinfo && !@url.query && !@url.fragment
            raise ArgumentError, "url must be an HTTP(S) base URL without credentials, query or fragment"
          end
          unless (api_key.nil? && present?(username) && present?(password)) ||
                 (present?(api_key) && username.nil? && password.nil?)
            raise ArgumentError, "provide either username and password or api_key"
          end
          if [username, password, api_key].compact.any? { |value| value.match?(/[\r\n]/) }
            raise ArgumentError, "credentials must be single-line strings"
          end
          unless page_size.is_a?(Integer) && page_size.positive? && max_pages.is_a?(Integer) && max_pages.positive?
            raise ArgumentError, "page_size and max_pages must be positive integers"
          end

          @username, @password, @api_key = username, password, api_key
          @page_size, @max_pages = page_size, max_pages
          @requester = requester || method(:default_request)
        rescue URI::InvalidURIError
          raise ArgumentError, "url is invalid", cause: nil
        end

        # 逐页获取并校验完整设备清单。
        def devices
          token = @api_key || authenticate
          rows = []
          seen_ips = {}
          offset = 0
          @max_pages.times do
            uri = endpoint("api/v1/search/device")
            uri.query = URI.encode_www_form(fields: FIELDS.join(","), limit: @page_size, offset: offset)
            page = request_json(uri, authorized_get(uri, token), allow_empty: true)
            validate_rows!(page)
            return rows.uniq if page.empty?

            raise Error, "Netdisco pagination did not advance" if page.all? { |row| seen_ips[row.fetch("ip")] }

            page.each { |row| seen_ips[row.fetch("ip")] = true }
            rows.concat(page)
            offset += @page_size
          end
          raise Error, "Netdisco inventory exceeded max_pages"
        rescue QueryRequired
          legacy_devices(token)
        end

        # 仅显示服务地址，避免凭据进入调试输出。
        def inspect = "#<#{self.class} url=#{@url.scheme}://#{@url.host}>"

        private

        # 在服务要求查询参数时使用兼容查询获取清单。
        def legacy_devices(token)
          uri = endpoint("api/v1/search/device")
          uri.query = URI.encode_www_form(q: "%", seeallcolumns: true)
          rows = request_json(uri, authorized_get(uri, token), allow_empty: true)
          validate_rows!(rows)
          rows.map { |row| row.slice(*FIELDS) }.uniq
        end

        # 使用账号密码登录并取得 API 密钥。
        def authenticate
          uri = endpoint("login")
          request = ::Net::HTTP::Post.new(uri)
          request.basic_auth(@username, @password)
          data = request_json(uri, request)
          token = data["api_key"] if data.is_a?(Hash)
          raise Error, "Netdisco login did not return an API key" unless present?(token) && !token.match?(/[\r\n]/)

          token
        end

        # 为清单查询建立带 API 密钥的请求。
        def authorized_get(uri, token)
          request = ::Net::HTTP::Get.new(uri)
          request["Authorization"] = "Apikey #{token}"
          request
        end

        # 以服务根地址构建 API 地址。
        def endpoint(path)
          uri = @url.dup
          uri.path = "#{uri.path.chomp("/")}/#{path}"
          uri
        end

        # 发起请求并将 HTTP 和 JSON 故障转换为客户端错误。
        def request_json(uri, request, allow_empty: false)
          request["Accept"] = "application/json"
          response = @requester.call(uri, request)
          body = response.body.to_s
          if response.code == "400"
            parsed = JSON.parse(body)
            raise QueryRequired, "Netdisco requires a search query" if parsed.is_a?(Hash) && parsed["error"] == "Missing query"
          end
          raise Error, "Netdisco request failed (HTTP #{response.code})" unless response.is_a?(::Net::HTTPSuccess)
          return [] if allow_empty && body.strip.empty?

          JSON.parse(body)
        rescue JSON::ParserError
          raise Error, "Netdisco returned invalid JSON", cause: nil
        rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => error
          raise Error, "Netdisco connection failed (#{error.class})", cause: nil
        end

        # 使用标准库 HTTP 客户端发送请求。
        def default_request(uri, request)
          ::Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: 10, read_timeout: 60, write_timeout: 10) { |http| http.request(request) }
        end

        # 校验清单的字段类型和设备地址。
        def validate_rows!(rows)
          valid = rows.is_a?(Array) && rows.all? do |row|
            row.is_a?(Hash) && present?(row["ip"]) &&
              FIELDS.drop(1).all? { |field| row[field].nil? || row[field].is_a?(String) }
          end
          raise Error, "Netdisco returned an invalid device inventory" unless valid
        end

        # 判断凭据字段是否为非空字符串。
        def present?(value) = value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
