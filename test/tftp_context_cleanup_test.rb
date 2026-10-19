# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

# 多服务器批次收尾遵守与设备作用域相同的首错与资源所有权契约。
class TftpContextCleanupTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_connection_capacity_is_limited_to_each_servers_selected_devices
    devices = (1..3).map { |i| Struct.new(:host).new("192.0.2.#{i}") }
    transfer = Struct.new(:server, :verification_root)
    transfers = devices.to_h do |device|
      server = device.host.end_with?("3") ? "192.0.2.20" : "192.0.2.10"
      [device.host, transfer.new(server, nil)]
    end
    plan = Struct.new(:selected).new(devices)
    capacities = []
    factory = ->(**options) { capacities << options.fetch(:parallel); Object.new }
    fleet = N::Fleet.new(inventory: [], credentials: ->(*) { nil }, report_store: nil)
    N::Tftp::Archive.stub(:new, factory) do
      fleet.stub(:validate_tftp_targets!, nil) do
        fleet.send(:tftp_contexts, plan, transfers, report_directory: "unused", preserve_history: true, parallel: 500)
      end
    end
    assert_equal [2, 1], capacities
  end

  def test_cleanup_failure_never_replaces_the_device_interrupt_or_skips_other_archives
    failure = Interrupt.new("fixture cancellation")
    closed = []
    with_fleet(closed, credentials: ->(*) { raise failure }) do |fleet, directory|
      observed = assert_raises(Interrupt) { run_backup(fleet, directory) }
      assert_same failure, observed
      assert_equal :interrupted, fleet.last_report.status
    end
    assert_equal [0, 1], closed
  end

  def test_normal_exit_attempts_every_archive_and_reports_the_first_close_failure
    closed = []
    with_fleet(closed, credentials: ->(*) { nil }) do |fleet, directory|
      error = assert_raises(IOError) { run_backup(fleet, directory) }
      assert_equal "first close failed", error.message
    end
    assert_equal [0, 1], closed
  end

  private

  # 使用本地归档替身核对关闭次序，不连接 SSH 或设备。
  def with_fleet(closed, credentials:)
    archives = 2.times.map do |index|
      Object.new.tap do |archive|
        archive.define_singleton_method(:upload_filename) { |device| device.tftp_filename }
        archive.define_singleton_method(:upload_and_archive) { |device, **, &block| block.call(device.tftp_filename) }
        archive.define_singleton_method(:close) do
          closed << index
          raise IOError, "#{index.zero? ? "first" : "second"} close failed"
        end
      end
    end
    factory = ->(**) { archives.shift }
    rows = (1..2).map { |i| { "ip" => "192.0.2.#{i}", "vendor" => "H3C" } }
    fleet = N::Fleet.new(inventory: Struct.new(:devices).new(rows), credentials: credentials, report_store: nil)
    Dir.mktmpdir do |directory|
      N::Tftp::Archive.stub(:new, factory) { yield fleet, directory }
    end
  end

  # 两台设备使用不同服务器，确保建立两个独立资源上下文。
  def run_backup(fleet, directory)
    fleet.tftp_backup_all(server: "192.0.2.10", servers: { "192.0.2.2" => "192.0.2.20" },
                          preserve_history: true, report_directory: directory, parallel: 1)
  end
end
