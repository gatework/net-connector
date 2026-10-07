# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector/netdisco"

class NetdiscoPlanTest < Minitest::Test
  Netdisco = Net::Connector::Netdisco

  def test_external_plans_reject_duplicate_hosts_before_credentials_or_directory_creation
    fleet = Netdisco::Fleet.new(settings: Netdisco::Settings.new(env: {}), result_store: nil,
                                credentials: ->(*) { flunk "invalid plan requested credentials" })
    rows = ["2001:db8::1", "2001:0db8:0:0:0:0:0:1"].each_with_index.map do |ip, index|
      Netdisco::Device.from_row({ "ip" => ip, "name" => "edge-#{index}", "vendor" => "H3C" }, rules: Netdisco::Rules.new)
    end
    Dir.mktmpdir do |root|
      directory = File.join(root, "new")
      %i[backup tftp].each do |mode|
        plan = Netdisco::Plan.new(mode: mode, inventory: rows, ready: [[0, rows.first], [1, rows.last]], outcomes: [nil, nil])
        assert_raises(ArgumentError) do
          if mode == :backup
            fleet.backup_all(plan: plan, directory: directory)
          else
            fleet.tftp_backup_all(server: "192.0.2.10", plan: plan, preserve_history: true, report_directory: directory)
          end
        end
        refute File.exist?(directory)
        skipped = Netdisco::Outcome.new(device: rows.last, status: :sample_limit, backup: nil, error_code: nil, error_type: nil)
        assert_raises(ArgumentError) { plan.with(ready: [[0, rows.first]], outcomes: [nil, skipped]).validate! }
      end
    end
  end

  def test_tftp_plan_rejects_collisions_between_distinct_ipv6_addresses
    rows = ["fe80::1%a", "fe80::1:a"].map do |host|
      { "ip" => host, "name" => "edge", "vendor" => "H3C" }
    end
    requested = []
    fleet = Netdisco::Fleet.new(client: Struct.new(:devices).new(rows), result_store: nil,
                                credentials: ->(device) { requested << device.host; nil })
    plan = fleet.plan_tftp_backup(limit_per_vendor: nil)

    assert plan.inventory.all?(&:ready?)
    assert_equal 2, plan.inventory.map(&:host).uniq.size
    assert_equal ["edge-fe80__1_a.cfg"], plan.inventory.map(&:tftp_filename).uniq
    assert_equal ["fe80::1%a"], plan.selected.map(&:host)
    assert_equal [nil, :remote_filename_collision], (plan.outcomes.map { |item| item&.status })

    batch = fleet.tftp_backup_all(server: "192.0.2.10", plan: plan)
    assert_equal [:missing_credentials, :remote_filename_collision], batch.outcomes.map(&:status)
    assert_equal ["fe80::1%a"], requested
  end

  def test_supplied_tftp_plan_cannot_bypass_collision_checks
    rows = ["fe80::1%a", "fe80::1:a"].map do |host|
      { "ip" => host, "name" => "edge", "vendor" => "H3C" }
    end
    requested = []
    fleet = Netdisco::Fleet.new(client: Struct.new(:devices).new(rows), result_store: nil,
                                credentials: ->(device) { requested << device.host; nil })
    plan = fleet.plan_tftp_backup(limit_per_vendor: nil)
    unsafe = plan.with(ready: plan.inventory.each_with_index.map { |device, index| [index, device] },
                       outcomes: [nil, nil])

    assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.10", plan: unsafe) }
    assert_empty requested
  end

  def test_sampling_reason_takes_precedence_for_unselected_palo_alto_devices
    rows = (1..3).map { |number| { "ip" => "192.0.2.#{number}", "vendor" => "Palo Alto" } }
    fleet = Netdisco::Fleet.new(client: Struct.new(:devices).new(rows), result_store: nil)
    plan = fleet.plan_tftp_backup(limit_per_vendor: 1)

    assert_equal ["192.0.2.1"], plan.selected.map(&:host)
    assert_equal [nil, :sample_limit, :sample_limit], (plan.outcomes.map { |item| item&.status })
  end

  def test_collision_winner_follows_sampling_order_and_results_keep_inventory_order
    rows = [3, 1, 2].map { |number| { "ip" => "192.0.2.#{number}", "vendor" => "Palo Alto" } }
    fleet = Netdisco::Fleet.new(client: Struct.new(:devices).new(rows), result_store: nil)
    plan = fleet.plan_tftp_backup

    assert_equal ["192.0.2.1"], plan.selected.map(&:host)
    assert_equal [:remote_filename_collision, nil, :remote_filename_collision], (plan.outcomes.map { |item| item&.status })
    assert_same plan, plan.validate!
  end

  def test_collision_skip_requires_a_matching_selected_filename
    rows = (1..2).map { |number| { "ip" => "192.0.2.#{number}", "vendor" => "H3C" } }
    fleet = Netdisco::Fleet.new(client: Struct.new(:devices).new(rows), result_store: nil)
    plan = fleet.plan_tftp_backup(limit_per_vendor: 1)
    invalid = plan.with(outcomes: [nil, plan.outcomes.last.with(status: :remote_filename_collision)])

    assert_raises(ArgumentError) { fleet.tftp_backup_all(server: "192.0.2.10", plan: invalid) }
  end

  def test_inventory_and_direct_backup_share_vendor_naming_without_creating_a_strategy
    connector_class = Net::Connector.vendor_class(:radware)
    strategy = Class.new(connector_class.profile.tftp_strategy) do
      def self.file_extension = "cfg"
    end
    profile = Net::Connector::Profile.define(parent: connector_class.profile) { tftp_strategy strategy }
    device = Netdisco::Device.from_row({ "ip" => "192.0.2.1", "name" => "edge", "vendor" => "Radware" },
                                       rules: Netdisco::Rules.new)
    connector_class.stub(:profile, profile) do
      strategy.stub(:new, ->(*) { flunk "生成文件名不应构造会话策略" }) do
        assert_equal "edge-192.0.2.1.cfg", device.tftp_filename
      end
    end
    assert_equal "192.0.2.1.cfg", strategy.new(Struct.new(:host).new(device.host)).default_path(nil)
  end

  def test_strategy_must_declare_its_filename_contract
    strategy = Class.new(Net::Connector.vendor_class(:h3c).profile.tftp_strategy)
    strategy.singleton_class.undef_method(:filename)
    assert_raises(ArgumentError) { Net::Connector::Profile.new(tftp_strategy: strategy) }
  end

end
