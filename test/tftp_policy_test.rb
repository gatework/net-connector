# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/net/connector/netdisco/tftp/policy"

class TftpPolicyTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_effective_options_use_device_overrides_and_bind_roots_to_the_matching_server
    Dir.mktmpdir do |root|
      policy = N::Tftp::Policy.new(server: "192.0.2.10", verification_root: root,
                                    servers: { "192.0.2.1" => "192.0.2.11" },
                                    vrfs: { hillstone: { default: "mgt-vr", hosts: { "192.0.2.1" => "trust-vr" } } })
      first = policy.for(host: "192.0.2.1", vendor: :hillstone)
      second = policy.for(host: "192.0.2.2", vendor: :hillstone)
      assert_equal "192.0.2.11", first.server
      assert_nil first.verification_root
      assert_equal "trust-vr", first.vrf
      assert_equal File.realpath(root), second.verification_root
      assert_equal "mgt-vr", second.vrf
      assert first.frozen?
    end
  end

  def test_source_files_and_interfaces_are_selected_and_frozen_per_device
    policy = N::Tftp::Policy.new(server: "192.0.2.10", source_files: { h3c: { default: "flash:/startup.cfg", hosts: { "192.0.2.1" => nil } } },
                                  source_interfaces: { h3c: { default: "management", hosts: { "192.0.2.1" => "Vlan-interface10" } } })
    item = policy.for(host: "192.0.2.1", vendor: :h3c)
    assert_nil item.source_file
    assert_equal "Vlan-interface10", item.source_interface
    assert item.source_interface.frozen?
    assert_equal "flash:/startup.cfg", policy.for(host: "192.0.2.2", vendor: :h3c).source_file
  end

  def test_server_roots_are_explicit_and_aliases_cannot_bind_one_root_to_distinct_servers
    Dir.mktmpdir do |root|
      assert_raises(ArgumentError) do
        N::Tftp::Policy.new(server: "192.0.2.10", verification_root: root, verification_roots: { "192.0.2.11" => root })
      end
      policy = N::Tftp::Policy.new(server: "192.0.2.10", servers: { "192.0.2.1" => "192.0.2.11" }, verification_roots: { "192.0.2.11" => root })
      assert_equal File.realpath(root), policy.for(host: "192.0.2.1", vendor: :h3c).verification_root
    end
  end

  def test_all_declared_values_are_validated_and_unknown_capability_is_not_ignored
    [{ vrfs: { h3c: "management" } }, { source_interfaces: { huawei: "management" } },
     { source_files: { hillstone: "startup.cfg" } }, { servers: { "192.0.2.0/24" => "192.0.2.11" } },
     { source_interfaces: { h3c: "bad;command" } }].each do |options|
      assert_raises(ArgumentError) { N::Tftp::Policy.new(server: "192.0.2.10", **options) }
    end
  end
end
