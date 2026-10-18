# frozen_string_literal: true

require "socket"

# 有限请求的真实 HTTP 服务；同时支持短连接与 keep-alive，退出时回收 socket 和线程。
class InventoryHTTPServer
  attr_reader :url, :connections, :requests

  def self.open(count:, close_connection: false, reply:)
    server = new(count: count, close_connection: close_connection, reply: reply)
    yield server
    raise "HTTP fixture did not terminate" unless server.join(4)
  ensure
    server&.close
  end

  def initialize(count:, close_connection:, reply:)
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}"
    @connections = 0
    @requests = []
    @worker = Thread.new do
      while @requests.size < count
        begin
          @socket = @server.accept
          @connections += 1
          while @requests.size < count && (request = @socket.gets)
            headers = +request
            while (line = @socket.gets) && line != "\r\n"
              headers << line
            end
            @requests << headers
            body = reply.call(headers)
            @socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n" \
                          "Connection: #{close_connection ? "close" : "keep-alive"}\r\n\r\n#{body}")
            break if close_connection
          end
        ensure
          @socket&.close
        end
      end
    end
  end

  def join(timeout)
    thread = @worker.join(timeout)
    return unless thread

    @worker.value
    thread
  end

  def close
    @worker.kill.join if @worker&.alive?
    @socket&.close
    @server&.close
  end
end
