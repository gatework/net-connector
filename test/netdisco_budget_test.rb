# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "socket"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class NetdiscoBudgetTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco
  Client = Netdisco::Client

  def response(body, code: "200")
    klass = code == "200" ? Net::HTTPOK : Net::HTTPBadRequest
    klass.new("1.1", code, "test").tap do |reply|
      reply.define_singleton_method(:body) { body }
    end
  end

  def row(index = 1) = { "ip" => "192.0.2.#{index}", "vendor" => "H3C" }

  def client(**options)
    Client.new(url: "https://inventory.example", api_key: "test", **options)
  end

  def assert_inventory_failure(client, code)
    calls = []
    fleet = Netdisco::Fleet.new(client: client, settings: Netdisco::Settings.new(env: {}), result_store: nil,
                                credentials: ->(*) { calls << :credentials },
                                connector_factory: ->(*) { calls << :connector })
    Dir.mktmpdir do |directory|
      error = assert_raises(Client::Error) { fleet.backup_all(directory: directory) }
      assert_equal code, error.code
      assert_nil error.cause
      refute_includes error.full_message, "unregistered-test-secret"
      assert_empty calls
      assert_empty Dir.children(directory)
      error
    end
  end

  def test_each_inventory_budget_rejects_invalid_values_before_requesting
    %i[page_size max_pages max_response_bytes max_inventory_bytes max_devices].each do |name|
      [0, -1, 1.5, Float::INFINITY, Float::NAN, "2", nil, true].each do |value|
        assert_raises(ArgumentError, "#{name}=#{value.inspect}") { client(**{ name => value }) }
      end
    end
    [0, -1, Float::INFINITY, Float::NAN, "2", nil, true].each do |value|
      assert_raises(ArgumentError) { client(inventory_timeout: value) }
    end
    assert_instance_of Client, client(inventory_timeout: 0.1)
    assert_raises(ArgumentError) { client(requester: Object.new) }
  end

  def test_old_requester_checks_single_response_bytes_before_json_parsing
    body = "unregistered-test-secret" * 100
    bounded = client(max_response_bytes: 40, requester: ->(*) { response(body) })
    assert_inventory_failure(bounded, :max_response_bytes)
  end

  def test_many_small_pages_share_cumulative_bytes_and_never_return_partial_inventory
    answers = 1.upto(10).map { |index| response([row(index)].to_json) }
    bounded = client(page_size: 1, max_response_bytes: 100, max_inventory_bytes: ([row].to_json.bytesize * 2) - 1,
                     requester: ->(*) { answers.shift })
    assert_inventory_failure(bounded, :max_inventory_bytes)
    assert_equal 8, answers.size
  end

  def test_device_limit_counts_records_before_deduplication_and_append
    answers = [response([row, row, row(2)].to_json), response("[]")]
    bounded = client(max_devices: 2, requester: ->(*) { answers.shift })
    assert_inventory_failure(bounded, :max_devices)
    assert_equal 1, answers.size
  end

  def test_legacy_query_uses_the_same_byte_and_device_limits
    missing = response({ error: "Missing query" }.to_json, code: "400")
    body = [row.merge("snmp_comm" => "unregistered-test-secret")].to_json
    answers = [missing, response(body)]
    bounded = client(max_inventory_bytes: body.bytesize, requester: ->(*) { answers.shift })
    assert_inventory_failure(bounded, :max_inventory_bytes)

    answers = [missing, response([row, row(2)].to_json)]
    assert_inventory_failure(client(max_devices: 1, requester: ->(*) { answers.shift }), :max_devices)
  end

  def test_authentication_and_pagination_share_a_monotonic_deadline
    now = 1.0
    calls = 0
    requester = lambda do |*_args|
      calls += 1
      now += 3
      response({ api_key: "unregistered-test-secret" }.to_json)
    end
    bounded = Client.new(url: "https://inventory.example", username: "reader", password: "test",
                         inventory_timeout: 2, requester: requester)
    bounded.stub(:monotonic, -> { now }) { assert_inventory_failure(bounded, :inventory_timeout) }
    assert_equal 1, calls
  end

  def test_legacy_query_cannot_restart_the_deadline
    now = 0.0
    answers = [response({ error: "Missing query" }.to_json, code: "400"), response([row].to_json)]
    requester = lambda do |*_args|
      now += 2
      answers.shift
    end
    bounded = client(inventory_timeout: 3, requester: requester)
    bounded.stub(:monotonic, -> { now }) { assert_inventory_failure(bounded, :inventory_timeout) }
    assert_empty answers
  end

  def test_compatibility_callback_is_checked_after_return_without_asynchronous_interruption
    now = 0.0
    completed = false
    bounded = client(inventory_timeout: 1, requester: lambda { |*_args|
      now = 10
      completed = true
      response("[]")
    })
    bounded.stub(:monotonic, -> { now }) { assert_inventory_failure(bounded, :inventory_timeout) }
    assert completed
  end

  def test_each_call_gets_new_budget_and_exact_limits_are_allowed
    body = [row].to_json
    answers = [response(body), response("[]"), response(body), response("[]")]
    bounded = client(max_devices: 1, max_response_bytes: body.bytesize,
                     max_inventory_bytes: body.bytesize + 2, requester: ->(*) { answers.shift })
    2.times { assert_equal [row], bounded.devices }
  end

  def test_http_policy_preserves_old_default_and_supports_explicit_rejection
    assert_instance_of Client, Client.new(url: "http://inventory.example", api_key: "test")
    assert_instance_of Client, Client.new(url: "http://inventory.example", api_key: "test", allow_insecure_http: true)
    error = assert_raises(ArgumentError) do
      Client.new(url: "http://inventory.example", api_key: "test", allow_insecure_http: false)
    end
    assert_includes error.message, "allow_insecure_http"
    assert_raises(ArgumentError) { client(allow_insecure_http: "false") }
  end

  def test_pagination_and_parse_failures_are_safe_and_do_not_start_connectors
    repeated = response([row].to_json)
    assert_inventory_failure(client(requester: ->(*) { repeated }), :pagination_stalled)
    assert_inventory_failure(client(max_pages: 1, requester: ->(*) { repeated }), :max_pages)
    assert_inventory_failure(client(requester: ->(*) { response("unregistered-test-secret") }), :invalid_json)
    assert_inventory_failure(client(requester: ->(*) { response('[{"ip":1}]') }), :invalid_inventory)
    assert_inventory_failure(client(requester: ->(*) { raise Net::HTTPBadResponse, "unregistered-test-secret" }),
                             :connection_failed)
    assert_inventory_failure(client(requester: ->(*) { raise Client::Error, "unregistered-test-secret" }),
                             :connection_failed)
  end

  # 模拟 read_body 的逐块交付：越界后若继续读取，测试会直接失败，不依赖耗时或分片大小。
  def test_default_http_checks_streamed_bytes_without_using_body_or_content_length
    [nil, "1", "999999999"].each do |advertised|
      received = []
      reply = Net::HTTPOK.new("1.1", "200", "OK")
      reply["Content-Length"] = advertised if advertised
      reply.define_singleton_method(:body) { raise "must use read_body" }
      reply.define_singleton_method(:read_body) do |&block|
        ["a" * 20, "b" * 21, "unread"].each do |chunk|
          received << chunk
          block.call(chunk)
        end
      end
      http = http_double
      http.define_singleton_method(:request) { |_request, &block| block.call(reply); reply }
      start = ->(*_args, **_options, &block) { block.call(http) }
      Net::HTTP.stub(:start, start) do
        assert_inventory_failure(client(max_response_bytes: 40), :max_response_bytes)
      end
      assert_equal 2, received.size
    end
  end

  def test_default_http_reduces_native_timeouts_between_received_chunks
    now = 10.0
    observed = []
    http = http_double
    reply = Net::HTTPOK.new("1.1", "200", "OK")
    reply.define_singleton_method(:read_body) do |&block|
      now = 11.0
      block.call("[")
      observed << http.read_timeout
      now = 12.0
      block.call("]")
      observed << http.read_timeout
    end
    http.define_singleton_method(:request) { |_request, &block| block.call(reply); reply }
    start_options = nil
    start = lambda do |*_args, **options, &block|
      start_options = options
      block.call(http)
    end
    bounded = client(inventory_timeout: 3)
    bounded.stub(:monotonic, -> { now }) do
      Net::HTTP.stub(:start, start) { assert_equal [], bounded.devices }
    end
    assert_equal [2.0, 1.0], observed
    assert_equal 3.0, start_options.fetch(:open_timeout)
    assert_equal 3.0, start_options.fetch(:read_timeout)
    assert_equal 3.0, start_options.fetch(:write_timeout)
    assert_equal 0, start_options.fetch(:max_retries)
    assert_equal true, start_options.fetch(:use_ssl)
  end

  def test_slow_chunks_use_the_original_deadline_even_when_each_read_progresses
    now = 0.0
    delivered = 0
    http = http_double
    reply = Net::HTTPOK.new("1.1", "200", "OK")
    reply.define_singleton_method(:read_body) do |&block|
      ["[", " ", "]"].each do |chunk|
        now += 1
        delivered += 1
        block.call(chunk)
      end
    end
    http.define_singleton_method(:request) { |_request, &block| block.call(reply); reply }
    start = ->(*_args, **_options, &block) { block.call(http) }
    bounded = client(inventory_timeout: 2)
    bounded.stub(:monotonic, -> { now }) do
      Net::HTTP.stub(:start, start) { assert_inventory_failure(bounded, :inventory_timeout) }
    end
    assert_equal 2, delivered
  end

  def test_real_http_aborts_oversized_bodies_before_server_finishes_transmission
    ["Transfer-Encoding: chunked\r\nContent-Length: 1", "Content-Length: 100000000", "Connection: close"].each do |headers|
      disconnected = Queue.new
      serve = lambda do |socket|
        socket.write("HTTP/1.1 200 OK\r\n#{headers}\r\n\r\n")
        socket.write("100000\r\n") if headers.start_with?("Transfer-Encoding")
        socket.write("x" * 64)
        ready = socket.wait_readable(3)
        disconnected << (ready && socket.read(1).nil?)
      end
      with_http_server(serve) do |url|
        bounded = Client.new(url: url, api_key: "test", max_response_bytes: 32, inventory_timeout: 2)
        assert_inventory_failure(bounded, :max_response_bytes)
      end
      assert_equal true, disconnected.pop
    end
  end

  def test_real_http_deadline_covers_incomplete_response_headers_and_closes_socket
    disconnected = Queue.new
    serve = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nX-Unfinished: ")
      ready = socket.wait_readable(3)
      disconnected << (ready && socket.read(1).nil?)
    end
    with_http_server(serve) do |url|
      bounded = Client.new(url: url, api_key: "test", inventory_timeout: 0.5)
      assert_inventory_failure(bounded, :inventory_timeout)
    end
    assert_equal true, disconnected.pop
  end

  def test_deadline_closes_owned_http_transport_even_while_native_chunk_reader_is_blocked
    threads_before = Thread.list
    closed = Queue.new
    http = http_double
    http.define_singleton_method(:finish) { closed << :closed }
    reply = Net::HTTPOK.new("1.1", "200", "OK")
    reply.define_singleton_method(:read_body) do |&_block|
      closed.pop
      raise IOError, "closed fixture reader"
    end
    http.define_singleton_method(:request) { |_request, &block| block.call(reply); reply }
    start = ->(*_args, **_options, &block) { block.call(http) }
    # 关闭异步 raise 路径，明确证明截止时间通过关闭自有传输解除阻塞；不靠 sleep 判断竞态。
    without_async_raise = ->(*_args, &block) { block.call }
    Timeout.stub(:timeout, without_async_raise) do
      Net::HTTP.stub(:start, start) do
        worker = Thread.new { assert_inventory_failure(client(inventory_timeout: 0.05), :inventory_timeout) }
        begin
          assert worker.join(2), "deadline did not close its owned HTTP transport"
          worker.value
        ensure
          worker.kill.join if worker.alive?
        end
      end
    end
    assert_empty Thread.list - threads_before, "owned deadline observer was not joined"
  end

  private

  def http_double
    Struct.new(:open_timeout, :read_timeout, :write_timeout, :max_retries).new.tap do |http|
      http.define_singleton_method(:finish) {}
    end
  end

  def with_http_server(serve)
    server = TCPServer.new("127.0.0.1", 0)
    worker = Thread.new do
      socket = server.accept
      while (line = socket.gets)
        break if line == "\r\n"
      end
      serve.call(socket)
    ensure
      socket&.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
    assert worker.join(4), "HTTP fixture did not terminate"
    worker.value
  ensure
    server&.close
    worker&.kill&.join if worker&.alive?
  end
end
