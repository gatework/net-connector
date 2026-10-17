# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "../lib/net/connector/concurrency/observer"
require_relative "../lib/net/connector/concurrency/pool"
require_relative "support/fake_transport"

class FailureCauseTest < Minitest::Test
  ENTRIES = %i[device_open device_scope observer pool].freeze

  ENTRIES.each do |entry|
    define_method("test_#{entry}_does_not_attach_an_unrelated_caller_rescue") do
      failure = failure_for(entry, cause: nil)
      observed = observe_in_rescue(entry, failure)
      assert_same failure, observed, entry.to_s
      assert_nil observed.cause, entry.to_s
      refute_includes observed.full_message, "unrelated caller detail"
    end
    define_method("test_#{entry}_preserves_the_original_cause") do
      cause = ArgumentError.new("original cause")
      failure = failure_for(entry, cause: cause)
      observed = observe_in_rescue(entry, failure)
      assert_same failure, observed, entry.to_s
      assert_same cause, observed.cause, entry.to_s
    end
  end

  private

  def failure_for(entry, cause:)
    type = entry == :device_scope ? Interrupt : IOError
    raise type.new("operation failure"), cause: cause
  rescue Exception => error # rubocop:disable Lint/RescueException -- Net::Connector::Device::Scope 只把非 StandardError 原样抛出。
    error
  end

  def observe_in_rescue(entry, failure)
    begin
      raise "unrelated caller detail"
    rescue RuntimeError
      operation = ->(*) { raise failure, cause: failure.cause }
      case entry
      when :device_open
        Net::Connector.open(:cisco_ios, host: "192.0.2.1", username: "operator",
                            transport: ConnectorFake.new("router#"), &operation)
      when :device_scope
        connector = Object.new
        connector.define_singleton_method(:close) {}
        Net::Connector::Device::Scope.call(factory: -> { connector }, &operation)
      when :observer
        Net::Connector::Concurrency::Observer.run(task: -> {}, stop: -> {}, &operation)
      when :pool
        Net::Connector::Concurrency::Pool.new(concurrency: 1).map([:item], &operation)
      end
    end
  rescue Exception => error # rubocop:disable Lint/RescueException -- 把原始取消转为可验证结果，不能提前终止测试。
    error
  end
end
