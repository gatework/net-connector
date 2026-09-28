# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class NetdiscoReliabilityTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def test_worker_interrupt_stops_other_device_tasks_before_returning
    first = Struct.new(:host).new("192.0.2.1")
    second = Struct.new(:host).new("192.0.2.2")
    second_started = Queue.new
    blocker = Queue.new
    other_thread = nil
    worker = Netdisco::Worker.new(concurrency: 2)

    assert_raises(Interrupt) do
      worker.run([[0, first], [1, second]], outcomes: Array.new(2), on_error: ->(*) { flunk "unexpected error callback" }) do |device|
        if device == first
          second_started.pop
          raise Interrupt
        end
        other_thread = Thread.current
        second_started << true
        blocker.pop
      end
    end
    refute other_thread.alive?
  ensure
    blocker&.push(true)
  end

  def test_interrupt_in_a_later_worker_does_not_wait_for_an_earlier_device
    first = Struct.new(:host).new("192.0.2.1")
    second = Struct.new(:host).new("192.0.2.2")
    started = Queue.new
    blocker = Queue.new
    threads = []
    thread_new = Thread.method(:new)
    worker = Netdisco::Worker.new(concurrency: 2)
    # 等首个线程确实进入设备任务后再创建第二个，固定复现等待顺序。
    spawn = lambda do |&operation|
      thread_new.call(&operation).tap do |thread|
        threads << thread
        started.pop if threads.size == 1
      end
    end
    runner = thread_new.call do
      Thread.stub(:new, spawn) do
        worker.run([[0, first], [1, second]], outcomes: Array.new(2), on_error: ->(*) { flunk "unexpected error callback" }) do |device|
          raise Interrupt, "later device interrupted" if device == second

          started << true
          blocker.pop
        end
      end
    rescue Interrupt => error
      error
    end

    assert runner.join(2), "后启动的线程中断后，批次不应继续等待前一台设备"
    assert_instance_of Interrupt, runner.value
    assert_equal "later device interrupted", runner.value.message
    refute threads.any?(&:alive?)
  ensure
    runner&.kill
    runner&.join
  end

  def test_worker_startup_failure_stops_already_started_device_tasks
    first = Struct.new(:host).new("192.0.2.1")
    second = Struct.new(:host).new("192.0.2.2")
    started = Queue.new
    blocker = Queue.new
    thread_new = Thread.method(:new)
    thread = nil
    spawn = lambda do |&operation|
      raise ThreadError, "cannot create worker" if thread

      thread = thread_new.call(&operation)
      started.pop
      thread
    end
    worker = Netdisco::Worker.new(concurrency: 2)
    Thread.stub(:new, spawn) do
      error = assert_raises(ThreadError) do
        worker.run([[0, first], [1, second]], outcomes: Array.new(2), on_error: ->(*) { flunk "unexpected error callback" }) do
          started << true
          blocker.pop
        end
      end
      assert_equal "cannot create worker", error.message
      refute thread.alive?, "线程创建失败后，已启动的设备任务必须完成清理"
    end
  ensure
    thread&.kill
    thread&.join
  end

  def test_tftp_filenames_accept_scoped_ipv6_and_fit_target_limits
    ["fe80::1%en0", "2001:db8:1234:5678:9012:3456:789a:bcde", "fe80::1%#{"a" * 240}"].each do |address|
      %w[H3C Hillstone Radware].each do |vendor|
        device = Netdisco::Device.from_row({ "ip" => address, "name" => "a" * 180, "vendor" => vendor },
                                           rules: Netdisco::Rules.new)
        assert device.ready?
        filename = device.tftp_filename
        target = Net::Connector::TftpTarget.new(host: "192.0.2.10", path: filename)
        assert_equal filename, target.path
        assert_equal filename, device.tftp_filename
      end
    end
  end

  def test_existing_valid_tftp_filename_is_preserved
    device = Netdisco::Device.from_row({ "ip" => "192.0.2.1", "name" => "core-a", "vendor" => "H3C" },
                                       rules: Netdisco::Rules.new)
    assert_equal "core-a-192.0.2.1.cfg", device.tftp_filename
  end

  def test_tftp_labels_are_validated_before_byte_truncation
    ["核心交换机", ("a" * 300) + "设备", "\xFF".b, 123].each do |label|
      error = assert_raises(ArgumentError) do
        Net::Connector::TftpTarget.filename("192.0.2.1", extension: "cfg", label: label)
      end
      assert_includes error.message, "TFTP label"
    end
    filename = Net::Connector::TftpTarget.filename("192.0.2.1", extension: "cfg", label: "a" * 300)
    assert_equal Net::Connector::TftpTarget::MAX_PATH_BYTES, filename.bytesize
    assert filename.end_with?("-192.0.2.1.cfg")
    assert_equal "site/core-192.0.2.1.cfg",
                 Net::Connector::TftpTarget.filename("192.0.2.1", extension: "cfg", label: "site/core")
  end

  def test_tftp_preview_and_execution_use_the_same_palo_alto_filename
    rows = [{ "ip" => "192.0.2.1", "name" => "firewall", "vendor" => "Palo Alto" }]
    paths = []
    factory = lambda do |settings|
      Netdisco::Fleet.new(settings: settings, client: Struct.new(:devices).new(rows), result_store: nil,
                          credentials: ->(_) { { username: "backup" } }, connector_factory: lambda { |*_args|
          Object.new.tap do |connector|
            connector.define_singleton_method(:tftp_backup) do |**options|
              paths << options.fetch(:path)
              Net::Connector::TftpReceipt.new(server: options.fetch(:host), path: paths.last, completed_at: Time.now.utc)
            end
            connector.define_singleton_method(:close) {}
          end
        })
    end
    output = StringIO.new
    error = StringIO.new
    Dir.mktmpdir do |directory|
      env = { "TFTP_HOST" => "192.0.2.10", "NC_BACKUP_DIRECTORY" => directory }
      cli = Netdisco::CLI.new(argv: %w[--tftp --plan], env: env, output: output, error: error, fleet_factory: factory)
      assert_equal 0, cli.run, error.string
      filename = JSON.parse(output.string).fetch("selected").first.fetch("filename")
      assert_equal "running-config.xml", filename
      assert_empty paths

      cli = Netdisco::CLI.new(argv: %w[--tftp], env: env, output: StringIO.new, error: error, fleet_factory: factory)
      assert_equal 0, cli.run, error.string
      assert_equal [filename], paths
    end
  end

  def test_client_does_not_expose_raw_response_through_exception_cause
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { "invalid-json private-api-token" }
    client = Netdisco::Client.new(url: "https://inventory.example", api_key: "token",
                                  requester: ->(*) { response })

    error = assert_raises(Netdisco::Client::Error) { client.devices }
    assert_equal "Netdisco returned invalid JSON", error.message
    assert_nil error.cause
    refute_includes error.full_message, "private-api-token"
  end

  def test_client_does_not_expose_transport_exception_credentials
    client = Netdisco::Client.new(url: "https://inventory.example", api_key: "token",
                                  requester: ->(*) { raise IOError, "private-api-token" })

    error = assert_raises(Netdisco::Client::Error) { client.devices }
    assert_equal "Netdisco connection failed (IOError)", error.message
    assert_nil error.cause
    refute_includes error.full_message, "private-api-token"
  end
end
