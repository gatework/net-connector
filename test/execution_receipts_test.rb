# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"

class ExecutionReceiptsTest < Minitest::Test
  Connector = Net::Connector

  def build(*events, **settings)
    @transport = ConnectorFake.new("fw#", *events)
    klass = Class.new(Connector::Base) do
      profile do
        prompts { login(/fw#\z/); command(/fw#\z/) }
        errors { command(/Error: rejected/) }
      end
    end
    @device = klass.new(host: "192.0.2.1", transport: @transport, **settings)
  end

  def teardown = @device&.close

  def test_completed_receipt_survives_original_event_cancellation
    interruption = Interrupt.new("cancel after response")
    callback = ->(event) { raise interruption if event.name == "command_complete" }
    build("configured\nfw#", on_event: callback)
    receipts, progress = [], []

    raised = assert_raises(Interrupt) do
      @device.execute_script(["configure", "never"], on_receipt: ->(step) { receipts << step }) { |step| progress << step }
    end

    assert_same interruption, raised
    assert_equal ["configure"], (receipts.map { |step| step.command.text })
    assert_equal ["configured\nfw#"], receipts.map(&:output)
    assert_empty progress
    assert_equal ["configure\n"], @transport.writes
    assert @transport.closed?
  end

  def test_receipts_and_progress_have_distinct_budget_boundaries
    response = "done\nfw#"
    build(response, max_script_output_bytes: response.bytesize - 1)
    receipts, progress = [], []

    result = @device.execute_script(["first", "never"], on_receipt: ->(step) { receipts << step }) { |step| progress << step }

    assert_instance_of Connector::ScriptOutputLimitExceeded, result.error
    assert_equal result.steps, receipts
    assert_equal 1, receipts.size
    assert_empty progress
    assert_equal ["first\n"], @transport.writes
  end

  def test_receipt_is_delivered_when_postprocessing_cancels
    build("done\nfw#")
    interruption = Interrupt.new("cancel in postprocessing")
    receipts = []

    raised = assert_raises(Interrupt) do
      @device.execute_operation(Connector::Script.new(["first", "never"]), name: :test,
                                after_command: ->(*) { raise interruption },
                                on_receipt: ->(step) { receipts << step })
    end

    assert_same interruption, raised
    assert_equal ["first"], (receipts.map { |step| step.command.text })
    assert_equal ["first\n"], @transport.writes
    assert @transport.closed?
  end

  def test_thread_termination_after_response_keeps_receipt_without_progress_or_replay
    build("done\nfw#", on_event: ->(event) { Thread.current.kill if event.name == "command_complete" })
    receipts, progress = [], []

    worker = Thread.new do
      @device.execute_script(["first", "never"], on_receipt: ->(step) { receipts << step }) { |step| progress << step }
    end

    assert worker.join(5), "execution thread did not terminate"
    assert_equal ["first"], (receipts.map { |step| step.command.text })
    assert_empty progress
    assert_equal ["first\n"], @transport.writes
    assert @transport.closed?
  ensure
    worker&.kill&.join
  end

  def test_receipt_failure_stops_following_writes_and_preserves_the_step
    build("done\nfw#")
    receipts = []
    result = @device.execute_script(["first", "never"], on_receipt: ->(step) { receipts << step; raise IOError, "receipt failed" })

    assert result.failure?
    assert_equal result.steps, receipts
    assert_equal 1, receipts.size
    assert_equal ["first\n"], @transport.writes
    assert @transport.closed?
  end

  def test_receipt_failure_cannot_replace_an_earlier_cancellation
    interruption = Interrupt.new("original cancellation")
    build("done\nfw#", on_event: ->(event) { raise interruption if event.name == "command_complete" })
    receipts = []
    raised = assert_raises(Interrupt) do
      @device.execute_script(["first"], on_receipt: ->(step) { receipts << step; raise IOError, "receipt failed" })
    end

    assert_same interruption, raised
    assert_equal 1, receipts.size
    assert_equal ["first\n"], @transport.writes
  end

  def test_secondary_receipt_exits_preserve_the_original_cancellation_control_flow
    %i[exception throw kill].product(%i[exception throw kill]).each do |original_exit, callback_exit|
      interruption = Interrupt.new("original cancellation")
      event_callback = lambda do |event|
        next unless event.name == "command_complete"

        case original_exit
        when :exception then raise interruption
        when :throw then throw :original, :original_exit
        when :kill then Thread.current.kill
        end
      end
      build("done\nfw#", on_event: event_callback)
      receipts = []
      receipt_callback = lambda do |step|
        receipts << step
        case callback_exit
        when :exception then raise IOError, "receipt failure"
        when :throw then throw :callback, :callback_exit
        when :kill then Thread.current.kill
        end
      end
      observed, continued = nil, false
      worker = Thread.new do
        observed = catch(:callback) do
          catch(:original) do
            @device.execute_script(["first", "never"], on_receipt: receipt_callback)
            continued = true
          end
        end
      rescue Exception => error # rubocop:disable Lint/RescueException -- 测试需观察取消的原始对象。
        observed = error
      end

      assert worker.join(5), "execution thread did not terminate"
      context = "original=#{original_exit}, callback=#{callback_exit}"
      refute continued, context
      case original_exit
      when :exception then assert_same interruption, observed, context
      when :throw then assert_equal :original_exit, observed, context
      when :kill then assert_nil observed, context
      end
      assert_equal ["first"], (receipts.map { |step| step.command.text }), context
      assert_equal ["first\n"], @transport.writes, context
      assert @transport.closed?, context
    ensure
      worker&.kill&.join
      @device&.close
    end
  end

  def test_timeout_and_device_rejection_do_not_invent_completed_receipts
    [:timeout, "Error: rejected\nfw#"].each do |event|
      build(event)
      receipts = []
      result = @device.execute_script(["first", "never"], on_receipt: ->(step) { receipts << step })

      assert result.failure?
      assert_empty result.steps
      assert_empty receipts
      assert_equal ["first\n"], @transport.writes
      @device.close
    end
  end

  def test_save_config_forwards_completion_receipts
    @transport = ConnectorFake.new("fw#", "saved\nfw#")
    klass = Class.new(Connector::Base) do
      profile do
        prompts { login(/fw#\z/); command(/fw#\z/) }
        commands { save_config "save" }
      end
    end
    @device = klass.new(host: "192.0.2.1", transport: @transport)
    receipts = []

    result = @device.save_config(on_receipt: ->(step) { receipts << step })

    assert result.success?
    assert_equal result.steps, receipts
    assert_equal ["save"], (receipts.map { |step| step.command.text })
  end

  def test_invalid_receipt_callbacks_are_rejected_before_connecting
    build
    [false, Object.new].each do |callback|
      assert_raises(ArgumentError) { @device.execute_script(["never"], on_receipt: callback) }
    end
    assert_equal 0, @transport.opens
    assert_empty @transport.writes
  end

  def test_default_calls_preserve_subclasses_with_the_original_script_signature
    @transport = ConnectorFake.new("fw#", "done\nfw#", "saved\nfw#")
    klass = Class.new(Connector::Base) do
      profile do
        prompts { login(/fw#\z/); command(/fw#\z/) }
        commands { save_config "save" }
      end

      def execute_script(script, &) = super(script, &) # rubocop:disable Lint/UselessMethodDefinition -- 固定旧子类的参数契约。
    end
    @device = klass.new(host: "192.0.2.1", transport: @transport)
    progress = []

    assert @device.execute_command("first") { |step| progress << step }.success?
    assert @device.save_config.success?
    assert_equal ["first"], (progress.map { |step| step.command.text })
    assert_equal ["first\n", "save\n"], @transport.writes
  end

  def test_receipt_errors_keep_the_sensitive_output_boundary
    secret = "private-device-output"
    build("#{secret}\nfw#")
    receipts = []

    result = @device.execute_command("show configuration", output_sensitive: true, on_receipt: lambda { |step|
      receipts << step
      raise IOError, step.output
    })

    assert result.failure?
    assert_equal result.steps, receipts
    assert_includes receipts.first.output, secret
    refute_includes result.error.inspect, secret
    refute_includes result.error.message, secret
    assert_nil result.error.cause
    assert @transport.closed?
  end
end
