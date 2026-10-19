# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector/netdisco/fleet"

class FleetOptionsTest < Minitest::Test
  N = Net::Connector::Netdisco

  def test_backup_options_own_directory_and_revalidate_updates
    directory = +"backups"
    options = N::Fleet.const_get(:BackupOptions).new(directory: directory, parallel: 2)
    directory.replace("changed")
    assert_equal "backups", options.directory
    assert options.directory.frozen?
    assert options.frozen?
    assert_raises(ArgumentError) { options.with(parallel: 0) }
    assert_raises(ArgumentError) { options.with(success_policy: :verified) }
    assert_raises(ArgumentError) { options.with(on_result: Object.new) }
    assert_equal :hostname_ip, options.with(filename_style: :hostname_ip).filename_style
  end

  def test_tftp_options_own_maps_and_validate_even_without_a_device
    sources = { h3c: +"startup.cfg" }
    vrfs = { cisco_nxos: +"management" }
    options = N::Fleet.const_get(:TftpOptions).new(server: "192.0.2.10", source_files: sources, vrfs: vrfs,
                                  parallel: 2, report_directory: "backups")
    sources[:h3c].replace("changed")
    vrfs[:cisco_nxos].replace("changed")
    assert_equal "startup.cfg", options.source_files.fetch(:h3c)
    assert_equal "management", options.vrfs.fetch(:cisco_nxos)
    assert options.source_files.frozen?
    assert options.source_files.fetch(:h3c).frozen?
    assert_raises(ArgumentError) { options.with(source_files: { h3c: "../invalid" }) }
    assert_raises(ArgumentError) { options.with(success_policy: :verified) }
    assert_raises(ArgumentError) { options.with(on_start: Object.new) }
  end
end
