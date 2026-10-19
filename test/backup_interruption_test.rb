# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "stringio"
require_relative "../lib/net/connector/netdisco"
require_relative "support/fake_transport"

class BackupInterruptionTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_cancel_preserves_completed_receipts_and_distinguishes_pending_tasks
    Dir.mktmpdir do |root|
      output = StringIO.new
      transports = [ConnectorFake.new("router#", "router#", "hostname fixture\nrouter#"),
                    ConnectorFake.new(->(*) { raise Interrupt }), ConnectorFake.new]
      inventory = Struct.new(:devices).new((1..3).map { |i| { "ip" => "192.0.2.#{i}", "vendor" => "Cisco", "os" => "ios" } })
      original = N::Fleet.method(:new)
      factory = lambda do |**options|
        original.call(**options, connector_factory: lambda do |device, settings|
          device.build_connector(**settings, transport: transports.fetch(device.host.split(".").last.to_i - 1))
        end)
      end
      N::Fleet.stub(:new, factory) do
        N::CLI::Credentials.stub(:resolve, [inventory, ->(*) { { username: "fixture" } }]) do
          status = N::CLI::Backup.new(argv: ["--directory", root, "--parallel", "1", "--json", "--quiet"],
                                     env: {}, output: output, error: StringIO.new).run
          assert_equal 130, status
        end
      end
      directory = Dir[File.join(root, "*")].first
      assert File.file?(File.join(directory, "summary.json")), "cancel must save the partial batch"
      report = JSON.parse(File.read(File.join(directory, "summary.json")))
      assert_equal "interrupted", report.fetch("status")
      refute report.fetch("policy_success")
      assert_equal(%w[backed_up interrupted not_started], report.fetch("devices").map { |device| device.fetch("status") })
      saved = report.fetch("devices").first
      assert_equal Digest::SHA256.file(saved.fetch("path")).hexdigest, saved.fetch("sha256")
      assert File.file?(File.join(directory, "summary.txt"))
      assert transports.first.closed?
      assert transports[1].closed?
      assert_empty transports[2].writes
      event = JSON.parse(File.readlines(File.join(directory, "events.jsonl")).first)
      assert_equal saved.fetch("path"), event.fetch("artifact").fetch("path")
      assert_equal saved.fetch("sha256"), event.fetch("artifact").fetch("sha256")
      assert_equal 130, JSON.parse(output.string.lines.last).fetch("exit_status")
    end
  end

  def test_cancel_report_write_failure_does_not_replace_the_original_interrupt
    Dir.mktmpdir do |directory|
      failure = Interrupt.new("cancel fixture")
      fleet = N::Fleet.new(inventory: Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }]),
                           credentials: ->(*) { raise failure }, report_store: Object.new.tap do |store|
                             store.define_singleton_method(:write) { |*_, **| raise IOError, "report unavailable" }
                           end)
      assert_same failure, assert_raises(Interrupt) { fleet.backup_all(directory: directory, parallel: 1) }
      assert_equal :interrupted, fleet.last_report.status
      assert_equal "IOError", fleet.last_report.report_error
    end
  end

  def test_cancel_after_workers_finish_still_publishes_the_completed_receipt
    Dir.mktmpdir do |directory|
      device = N::Device.from_row({ "ip" => "192.0.2.1", "vendor" => "H3C" }, rules: N::Rules.new)
      receipt = Net::Connector::Backup.new(path: File.join(directory, "saved.txt"), bytes: 1, sha256: "a" * 64,
                                            collected_at: Time.now.utc)
      connector = Object.new
      connector.define_singleton_method(:backup) { |**| receipt }
      connector.define_singleton_method(:close) {}
      fleet = N::Fleet.new(inventory: Struct.new(:devices).new([{ "ip" => device.host, "vendor" => "H3C" }]),
                           credentials: ->(*) { { username: "fixture" } }, connector_factory: ->(*) { connector }, report_store: nil)
      build = N::Batch.method(:new)
      failure = Interrupt.new("after worker completion")
      first = true
      factory = lambda do |**values|
        if first
          first = false
          raise failure
        end
        build.call(**values)
      end
      N::Batch.stub(:new, factory) do
        assert_same failure, assert_raises(Interrupt) { fleet.backup_all(directory: directory, parallel: 1) }
      end
      assert_equal :interrupted, fleet.last_report.status
      assert_same receipt, fleet.last_report.outcomes.first.backup
      assert_equal :backed_up, fleet.last_report.outcomes.first.status
      refute fleet.last_report.policy_success?
    end
  end

end
