# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class TftpPlanPolicyTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_plan_freezes_effective_options_and_checks_filename_collisions_per_server
    rows = [{ "ip" => "192.0.2.1", "vendor" => "Palo Alto Networks" }, { "ip" => "192.0.2.2", "vendor" => "Palo Alto Networks" }]
    devices = rows.map { |row| N::Device.from_row(row, rules: N::Rules.new) }
    policy = N::Tftp::Policy.new(server: "192.0.2.10", servers: { "192.0.2.2" => "192.0.2.11" })
    plan = N::Planner.new(devices).call(mode: :tftp, limit_per_vendor: nil, tftp_policy: policy)
    assert_equal 2, plan.selected.size
    assert_same plan, plan.validate!
    assert_equal "192.0.2.10", plan.transfers.fetch("192.0.2.1").server
    assert_equal "192.0.2.11", plan.transfers.fetch("192.0.2.2").server
    assert plan.transfers.frozen?
    forged = plan.with(transfers: {})
    assert_raises(ArgumentError) { forged.validate! }
  end

  def test_fleet_uses_each_planned_server_source_and_vrf_and_rejects_execution_drift
    rows = [{ "ip" => "192.0.2.1", "vendor" => "Hillstone" }, { "ip" => "192.0.2.2", "vendor" => "Hillstone" }]
    defaults = { "NC_TFTP_HOST" => "192.0.2.10", "NC_TFTP_SERVERS" => JSON.generate("192.0.2.2" => "192.0.2.11"),
                 "NC_TFTP_VRFS" => JSON.generate("hillstone" => { "default" => "mgt-vr", "hosts" => { "192.0.2.2" => "trust-vr" } }) }
    received = {}
    factory = lambda do |device, _options|
      Object.new.tap do |connector|
        connector.define_singleton_method(:tftp_backup) do |**options|
          received[device.host] = options
          Net::Connector::TftpReceipt.new(server: options[:host], path: options[:path], completed_at: Time.now.utc)
        end
        connector.define_singleton_method(:close) {}
      end
    end
    fleet = N::Fleet.new(settings: N::Settings.new(env: {}, defaults: defaults), inventory: Struct.new(:devices).new(rows),
                          report_store: nil, credentials: ->(*) { { username: "audit" } }, connector_factory: factory)
    plan = fleet.plan_tftp_backup(limit_per_vendor: nil)
    assert fleet.tftp_backup_all(plan: plan).success?
    assert_equal "192.0.2.10", received.fetch("192.0.2.1").fetch(:host)
    assert_equal "192.0.2.11", received.fetch("192.0.2.2").fetch(:host)
    assert_equal "trust-vr", received.fetch("192.0.2.2").fetch(:vrf)
    received.clear
    assert_raises(ArgumentError) { fleet.tftp_backup_all(plan: plan, server: "192.0.2.12") }
    assert_empty received
  end

  def test_only_device_server_and_matching_verification_root_do_not_require_global_defaults
    Dir.mktmpdir do |root|
      row = { "ip" => "192.0.2.1", "vendor" => "H3C" }
      defaults = N::ConfigFile.parse("tftp" => { "servers" => { "192.0.2.1" => "192.0.2.10" },
                                                "verification_roots" => { "192.0.2.10" => root } })
      factory = lambda do |*|
        Object.new.tap do |connector|
          connector.define_singleton_method(:tftp_backup) do |**options|
            File.write(File.join(root, options[:path]), "configuration")
            Net::Connector::TftpReceipt.new(server: options[:host], path: options[:path], completed_at: Time.now.utc)
          end
          connector.define_singleton_method(:close) {}
        end
      end
      fleet = N::Fleet.new(settings: N::Settings.new(env: {}, defaults: defaults), inventory: Struct.new(:devices).new([row]),
                            report_store: nil, credentials: ->(*) { { username: "audit" } }, connector_factory: factory)
      report = fleet.tftp_backup_all(success_policy: :verified)
      assert report.policy_success?
      assert_equal :server_verified, report.outcomes.first.backup.verification
    end
  end

  def test_explicit_server_override_cannot_rebind_the_old_server_verification_root
    Dir.mktmpdir do |root|
      defaults = N::ConfigFile.parse("tftp" => { "server" => "192.0.2.10", "verification_root" => root })
      calls = []
      fleet = N::Fleet.new(settings: N::Settings.new(env: {}, defaults: defaults),
                            inventory: Struct.new(:devices).new([{ "ip" => "192.0.2.1", "vendor" => "H3C" }]), report_store: nil,
                            credentials: ->(device) { calls << device.host; nil })
      assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.11", success_policy: :verified) }
      assert_empty calls
    end
  end

  def test_identical_fixed_filenames_are_verified_and_archived_in_their_own_server_roots
    Dir.mktmpdir do |directory|
      roots = (1..2).map { |index| File.join(directory, "server#{index}").tap { |path| Dir.mkdir(path, 0o700) } }
      report_directory = File.join(directory, "report")
      rows = (1..2).map { |index| { "ip" => "192.0.2.#{index}", "vendor" => "Palo Alto Networks" } }
      servers = { "192.0.2.1" => "192.0.2.10", "192.0.2.2" => "192.0.2.11" }
      server_roots = servers.values.zip(roots).to_h
      defaults = N::ConfigFile.parse("tftp" => { "servers" => servers, "verification_roots" => server_roots })
      received = []
      factory = lambda do |device, _options|
        Object.new.tap do |connector|
          connector.define_singleton_method(:tftp_backup) do |**options|
            received << options
            File.write(File.join(server_roots.fetch(options.fetch(:host)), options.fetch(:path)), "configuration for #{device.host}")
            Net::Connector::TftpReceipt.new(server: options[:host], path: options[:path], completed_at: Time.now.utc)
          end
          connector.define_singleton_method(:close) {}
        end
      end
      fleet = N::Fleet.new(settings: N::Settings.new(env: {}, defaults: defaults), inventory: Struct.new(:devices).new(rows),
                            report_store: nil, credentials: ->(*) { { username: "audit" } }, connector_factory: factory)
      plan = fleet.plan_tftp_backup(limit_per_vendor: nil)
      assert_equal 2, plan.selected.size
      report = fleet.tftp_backup_all(plan: plan, success_policy: :verified, preserve_history: true, report_directory: report_directory)
      assert report.policy_success?, report.outcomes.inspect
      assert_equal(["running-config.xml", "running-config.xml"], received.map { |options| options.fetch(:path) })
      report.outcomes.each do |outcome|
        receipt = outcome.backup
        assert_equal :server_verified, receipt.verification
        assert_equal "configuration for #{outcome.device.host}", File.read(receipt.local_path)
        assert_equal File.read(receipt.local_path), File.read(receipt.archive_path)
        refute File.file?(File.join(server_roots.fetch(receipt.server), receipt.path))
      end
      assert_equal 2, report.outcomes.map { |outcome| outcome.backup.archive_path }.uniq.size
    end
  end

end
