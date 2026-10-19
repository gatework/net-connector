# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "timeout"
require_relative "../lib/net/connector/netdisco/cli/topology"

class CLITopologyInterruptionTest < Minitest::Test
  C = Net::Connector
  N = C::Netdisco

  # 模拟作用域已返回完成事实、外层尚未保存返回值时收到异步取消。
  def test_pending_cancel_preserves_the_completed_apply_receipt
    with_apply_cli do |cli, calls, root|
      cli.define_singleton_method(:perform_value) do |*arguments, &operation|
        value = super(*arguments, &operation)
        Thread.current.raise(Interrupt.new("cancel at completed return")) if value[:status] == :applied
        value
      end

      assert_equal 130, cli.run
      item = saved_device(root)
      assert_equal "applied", item.fetch("status")
      assert_equal 1, item.fetch("steps")
      assert_equal 1, calls.count(:applied)
      assert_equal 2, calls.count(:closed)
    end
  end

  # 同步故障先转换成已知失败事实，待交付的取消不能把它退化为未知中断。
  def test_pending_cancel_keeps_a_synchronous_operation_failure
    with_apply_cli do |cli, _calls, root|
      cli.define_singleton_method(:perform_value) do |*arguments, &operation|
        value = super(*arguments, &operation)
        if value[:status] == :applied
          Thread.handle_interrupt(Exception => :never) do
            Thread.current.raise(Interrupt.new("pending cancel"))
            raise IOError, "private completion failure"
          end
        end
        value
      end

      assert_equal 130, cli.run
      item = saved_device(root)
      assert_equal "failed", item.fetch("status")
      assert_equal "IOError", item.fetch("diagnostic").fetch("error_type")
    end
  end

  def test_blocking_apply_remains_cancelable_and_closes_its_connector
    entered, blocker = Queue.new, Queue.new
    with_apply_cli(on_apply: -> { entered << true; blocker.pop }) do |cli, calls, root|
      thread = Thread.new { cli.run }
      thread.report_on_exception = false
      Timeout.timeout(3) { entered.pop }
      thread.raise(Interrupt.new("cancel blocked apply"))

      assert_equal 130, Timeout.timeout(3) { thread.value }
      assert_equal "interrupted", saved_device(root).fetch("status")
      refute_includes calls, :applied
      assert_equal 2, calls.count(:closed)
    ensure
      blocker << true
      thread&.kill
      thread&.join
    end
  end

  private

  def saved_device(root)
    path = Dir.glob(File.join(root, "*", "summary.json")).fetch(0)
    JSON.parse(File.read(path)).fetch("devices").fetch(0)
  end

  # 仅替换设备 I/O；CLI 的计划持久化、作用域清理、事件登记和最终报告均实际运行。
  def with_apply_cli(on_apply: nil)
    Dir.mktmpdir do |root|
      inventory = Struct.new(:devices).new([{ "ip" => "192.0.2.1", "name" => "edge", "vendor" => "H3C" }])
      plan = C::Interfaces::Plan.new(host: "192.0.2.1", vendor: :h3c, evidence: {}, changes: [], commands: [])
      calls = []
      factory = lambda do |*|
        Object.new.tap do |connector|
          connector.define_singleton_method(:interfaces) { self }
          connector.define_singleton_method(:audit) do |**|
            C::Interfaces::Audit.new(plan: plan, comparisons: [], issues: [], manual_required: false)
          end
          connector.define_singleton_method(:apply) do |value, confirmed:|
            raise "incorrect plan or confirmation" unless value.equal?(plan) && confirmed

            on_apply&.call
            calls << :applied
            step = C::Command::Result.new(command: C::Command.new("description reviewed"),
                                          output: "completed", prompt: "<edge>", duration: 0.001)
            C::Result.new(steps: [step])
          end
          connector.define_singleton_method(:close) { calls << :closed }
        end
      end
      cli = N::CLI::Topology.new(argv: ["--apply", "--no-progress"], env: {}, default_directory: root,
                                connector_factory: factory, output: StringIO.new, error: StringIO.new)
      N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "audit" } }]) do
        yield cli, calls, root
      end
    end
  end
end
