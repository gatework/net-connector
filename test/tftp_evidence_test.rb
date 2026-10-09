# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/net/connector"
require_relative "support/fake_transport"
require_relative "support/tftp_fixture"

class TftpEvidenceTest < Minitest::Test
  CASES = TftpFixture::CASES

  CASES.each do |vendor, (prompt, command, success, path)|
    define_method("test_#{vendor}_command_echo_does_not_confirm_transfer") do
      with_device(vendor, prompt, "#{command}\r\n#{prompt}") do |device|
        error = assert_raises(Net::Connector::DeviceError) { backup(device, vendor, path) }
        assert_equal :transfer_unconfirmed, error.code
      end
    end

    define_method("test_#{vendor}_explicit_completion_confirms_transfer") do
      with_device(vendor, prompt, "#{command}\r\n#{success}\r\n#{prompt}") do |device|
        assert_equal path, backup(device, vendor, path).path
      end
    end

    define_method("test_#{vendor}_failure_after_success_overrides_completion") do
      with_device(vendor, prompt, "#{success}\r\nTransfer failed.\r\n#{prompt}") do |device|
        error = assert_raises(Net::Connector::DeviceError) { backup(device, vendor, path) }
        assert_equal :transfer_failed, error.code
      end
    end
  end

  def test_nxos_complete_filename_and_vrf_are_not_completion_messages
    %w[complete.cfg copy-success.cfg transfer-complete.cfg].each do |path|
      command = "copy running-config tftp://192.0.2.10/#{path} vrf copy-complete"
      with_device(:cisco_nxos, "switch#", "#{command}\r\nswitch#") do |device|
        error = assert_raises(Net::Connector::DeviceError) do
          device.tftp_backup(host: "192.0.2.10", path: path, vrf: "copy-complete")
        end
        assert_equal :transfer_unconfirmed, error.code
      end
    end
  end

  def test_radware_interactive_filename_echo_does_not_confirm_transfer
    with_device(:radware, ">> Main#", "Enter name of file on FTP/TFTP/SCP server:", "config-uploaded.tgz\r\n>> Main#") do |device|
      error = assert_raises(Net::Connector::DeviceError) { backup(device, :radware, "config-uploaded.tgz") }
      assert_equal :transfer_unconfirmed, error.code
    end
  end

  def test_radware_success_words_in_prompt_do_not_confirm_transfer
    with_device(:radware, ">> config complete#", ">> config complete#") do |device|
      error = assert_raises(Net::Connector::DeviceError) { backup(device, :radware, "backup.tgz") }
      assert_equal :transfer_unconfirmed, error.code
    end
  end

  def test_future_or_incomplete_transfer_messages_are_not_completion
    { cisco_nxos: ["Copy will complete after validation", "Copy successful.cfg"],
      h3c: ["Transfer completion pending", "Upload successful.cfg"],
      huawei: ["Transfer complete.cfg", "Upload success pending"],
      radware: ["Configuration will be uploaded", "Configuration complete pending"] }.each do |vendor, messages|
      prompt, _, _, path = CASES.fetch(vendor)
      messages.each do |message|
        with_device(vendor, prompt, "#{message}\r\n#{prompt}") do |device|
          error = assert_raises(Net::Connector::DeviceError, "#{vendor}: #{message}") { backup(device, vendor, path) }
          assert_equal :transfer_unconfirmed, error.code
        end
      end
    end
  end

  def test_zero_or_mismatched_progress_is_not_completion
    %i[h3c huawei].each do |vendor|
      prompt, _, _, path = CASES.fetch(vendor)
      ["100  0    0     0  100  0", "100  1000    0     0  100  10"].each do |progress|
        with_device(vendor, prompt, "#{progress}\r\n#{prompt}") do |device|
          error = assert_raises(Net::Connector::DeviceError, "#{vendor}: #{progress}") { backup(device, vendor, path) }
          assert_equal :transfer_unconfirmed, error.code
        end
      end
    end
  end

  def test_failure_evidence_survives_terminal_edits
    ["Transfer \e[31mfailed\e[0m.\n", "Transfer failed.\rTransfer complete.\n",
     "Transfer fa\e[31miled\e[0m.\rTransfer complete.\n"].each do |failure|
      with_device(:h3c, "<H3C>", "Transfer complete.\n#{failure}<H3C>") do |device|
        error = assert_raises(Net::Connector::DeviceError) { backup(device, :h3c, "backup.cfg") }
        assert_equal :transfer_failed, error.code
      end
    end
  end

  def test_failure_event_sink_cannot_replace_transfer_evidence
    { "Transfer failed." => :transfer_failed, "Upload starting" => :transfer_unconfirmed }.each do |response, code|
      observer = lambda do |event|
        raise IOError, "private event failure" if event.name == "tftp_backup"
      end
      with_device(:h3c, "<H3C>", "#{response}\n<H3C>", on_event: observer) do |device|
        failure = assert_raises(Net::Connector::DeviceError) { backup(device, :h3c, "backup.cfg") }
        assert_equal code, failure.code
        assert_nil failure.cause
        assert_equal 1, device.instance_variable_get(:@session).transport.writes.size
      end
    end
  end

  private

  def backup(device, vendor, path)
    options = { host: "192.0.2.10", path: path }
    options[:source_file] = "startup.cfg" if %i[h3c huawei].include?(vendor)
    device.tftp_backup(**options)
  end

  def with_device(vendor, *events, **options)
    device = Net::Connector.build(vendor, host: "192.0.2.1", username: "admin", transport: ConnectorFake.new(*events), **options)
    yield device
  ensure
    device&.close
  end
end
