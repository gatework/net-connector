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

  def test_failure_words_in_command_echo_do_not_reject_completed_upload
    ["error", "failed", "timeout"].each do |server|
      command = "tftp #{server} put startup.cfg backup.cfg"
      [command, "<H3C>#{command}", "\e[32m#{command}\e[0m", "#{command}\r#{command}"].each do |echo|
        with_device(:h3c, "<H3C>", "#{echo}\r\n123 bytes sent\r\n<H3C>") do |device|
          receipt = device.tftp_backup(host: server, path: "backup.cfg", source_file: "startup.cfg")
          assert_equal "backup.cfg", receipt.path
        end
      end
    end
  end

  def test_failure_words_in_source_and_destination_echo_do_not_reject_completed_upload
    command = "tftp 192.0.2.10 put timeout failed"
    with_device(:h3c, "<H3C>", "#{command}\r\n123 bytes sent\r\n<H3C>") do |device|
      receipt = device.tftp_backup(host: "192.0.2.10", path: "failed", source_file: "timeout")
      assert_equal "failed", receipt.path
    end
  end

  def test_failure_outputs_keep_evidence_from_prior_steps
    strategy = Net::Connector::Tftp::Strategy.new(nil)
    steps = ["Transfer failed.", "123 bytes copied"].map do |output|
      Net::Connector::CommandResult.new(command: Net::Connector::Command.new("copy config"),
                                       output: output, prompt: "switch#", duration: 0)
    end
    result = Net::Connector::Result.new(steps: steps)
    assert_includes strategy.failure_outputs(result), "Transfer failed."
  end

  def test_failure_words_in_interaction_echo_do_not_reject_completed_upload
    with_device(:cisco_nxos, "switch#", "Enter vrf (management):", "error\r\n123 bytes copied\r\nswitch#") do |device|
      assert_equal "backup.cfg", device.tftp_backup(host: "192.0.2.10", path: "backup.cfg", vrf: "error").path
    end
  end

  def test_echo_filter_does_not_hide_overwritten_failure_or_attached_diagnostic
    command = "tftp error put startup.cfg backup.cfg"
    ["Transfer failed.\r#{command}\r\n", "#{command}: Transfer failed.\r\n",
     "Transfer failed.\e[2K\e[1G#{command}\r\n"].each do |output|
      with_device(:h3c, "<H3C>", "#{output}123 bytes sent\r\n<H3C>") do |device|
        error = assert_raises(Net::Connector::DeviceError) do
          device.tftp_backup(host: "error", path: "backup.cfg", source_file: "startup.cfg")
        end
        assert_equal :transfer_failed, error.code
      end
    end
  end

  def test_independent_strategy_keeps_existing_interface_contract
    native = Net::Connector.vendor_class(:h3c)
    implementation = native.profile.tftp_strategy
    strategy = Class.new do
      define_method(:initialize) { |device| @delegate = implementation.new(device) }
      %i[resolve_source_file default_path remote_path script device_reported_complete? validate_options! receipt_metadata].each do |name|
        define_method(name) { |*arguments, **options| @delegate.public_send(name, *arguments, **options) }
      end
      define_singleton_method(:filename) { |host, **options| implementation.filename(host, **options) }
    end
    variant = Class.new(native)
    variant.profile { tftp_strategy strategy }
    device = variant.new(host: "192.0.2.1", username: "admin",
                         transport: ConnectorFake.new("<H3C>", "tftp error put startup.cfg backup.cfg\n123 bytes sent\n<H3C>"))
    assert_equal "backup.cfg", device.tftp_backup(host: "error", path: "backup.cfg", source_file: "startup.cfg").path
  ensure
    device&.close
  end

  def test_independent_strategy_filters_static_interaction_echo
    native = Net::Connector.vendor_class(:cisco_nxos)
    implementation = native.profile.tftp_strategy
    strategy = Class.new do
      define_method(:initialize) { |device| @delegate = implementation.new(device) }
      %i[resolve_source_file default_path remote_path script device_reported_complete? validate_options! receipt_metadata].each do |name|
        define_method(name) { |*arguments, **options| @delegate.public_send(name, *arguments, **options) }
      end
      define_singleton_method(:filename) { |host, **options| implementation.filename(host, **options) }
    end
    variant = Class.new(native)
    variant.profile { tftp_strategy strategy }
    device = variant.new(host: "192.0.2.1", username: "admin",
                         transport: ConnectorFake.new("switch#", "Enter vrf (management):", "error\n123 bytes copied\nswitch#"))
    assert_equal "backup.cfg", device.tftp_backup(host: "192.0.2.10", path: "backup.cfg", vrf: "error").path
  ensure
    device&.close
  end

  def test_failure_outputs_never_evaluate_dynamic_interaction_response
    calls = 0
    interaction = Net::Connector::Interaction.new(/answer:/, ->(_prompt) { calls += 1; "error\n" })
    command = Net::Connector::Command.new("copy config", interactions: [interaction])
    step = Net::Connector::CommandResult.new(command: command, output: "Transfer failed.", prompt: "switch#", duration: 0)
    Net::Connector::Tftp::Strategy.new(nil).failure_outputs(Net::Connector::Result.new(steps: [step])).to_a
    assert_equal 0, calls
  end

  def test_failure_split_by_color_and_erased_by_cursor_is_preserved
    command = "tftp 192.0.2.10 put startup.cfg backup.cfg"
    output = "Transfer fa\e[31miled.\e[0m\e[2K\e[1G#{command}\r\n123 bytes sent\r\n<H3C>"
    with_device(:h3c, "<H3C>", output) do |device|
      error = assert_raises(Net::Connector::DeviceError) { backup(device, :h3c, "backup.cfg") }
      assert_equal :transfer_failed, error.code
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
