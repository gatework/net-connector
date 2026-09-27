# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require "tmpdir"
require_relative "../lib/net/connector"
require_relative "support/topology_fixture"

class TopologyStagesTest < Minitest::Test
  def each_device
    TopologyFixture::SAMPLES.each_key do |vendor|
      fixture = TopologyFixture.new(vendor)
      begin
        yield fixture
      ensure
        fixture.close
      end
    end
  end

  def test_plan_includes_readback_and_apply_reads_effective_state_before_saving
    each_device do |fixture|
      plan = fixture.device.plan_interface_descriptions { "planned" }
      expected = [fixture.sample.fetch(:leave), *fixture.device.config_commands, fixture.sample.fetch(:save)]
      assert_equal expected, plan.commands.last(expected.size), fixture.device.vendor.to_s
      start = fixture.observed.size
      result = fixture.device.apply_interface_descriptions(plan, confirmed: true)
      assert result.success?, result.error.inspect
      sent = fixture.observed.drop(start)
      changed = sent.index { |command, _| command == "description planned" }
      verified = sent.rindex { |command, _| command == fixture.sample.fetch(:collect) }
      saved = sent.index { |command, _| command == fixture.sample.fetch(:save) }
      assert_operator changed, :<, verified
      assert_operator verified, :<, saved
      assert_equal :exec, sent.fetch(verified).last
      assert_equal :exec, sent.fetch(saved).last
      assert_equal "planned", fixture.description
      assert_equal sent.drop_while { |command, _| command != fixture.sample.fetch(:enter) }.map(&:first),
                   (result.steps.map { |step| step.command.text })
    end
  end

  def test_readback_mismatch_and_partial_parse_never_save
    [:mismatch, :partial_readback].each do |fault|
      each_device do |fixture|
        plan = fixture.device.plan_interface_descriptions { "planned" }
        fixture.public_send("#{fault}=", true)
        result = fixture.device.apply_interface_descriptions(plan, confirmed: true)
        assert result.failure?, "#{fixture.device.vendor}: #{fault}"
        assert_equal fault == :mismatch ? :description_unconfirmed : :unrecognized_output, result.error.code
        refute_includes fixture.transport.writes, "#{fixture.sample.fetch(:save)}\n"
        assert_includes result.steps.map { |step| step.command.text }, "description planned"
        assert_includes result.steps.map { |step| step.command.text }, fixture.sample.fetch(:collect)
      end
    end
  end

  def test_timeout_in_each_stage_stops_later_actions_and_preserves_completed_steps
    %i[enter change leave verify persist].each do |phase|
      each_device do |fixture|
        plan = fixture.device.plan_interface_descriptions { "planned" }
        target = { enter: fixture.sample.fetch(:enter), change: "description planned", leave: fixture.sample.fetch(:leave),
                   verify: fixture.sample.fetch(:collect), persist: fixture.sample.fetch(:save) }.fetch(phase)
        if phase == :verify
          fixture.on_command = ->(command) { fixture.fail_on = target if command == "description planned" }
        else
          fixture.fail_on = target
        end
        result = fixture.device.apply_interface_descriptions(plan, confirmed: true)
        assert result.failure?, "#{fixture.device.vendor}: #{phase}"
        assert_equal phase == :persist ? :persistence_unconfirmed : :command_timeout, result.error.code
        assert_equal "#{target}\n", fixture.transport.writes.last
        refute_includes fixture.transport.writes, "#{fixture.sample.fetch(:save)}\n" unless phase == :persist
        assert_includes result.steps.map { |step| step.command.text }, "description planned" if %i[leave verify persist].include?(phase)
      end
    end
  end

  def test_prompt_only_or_failed_save_is_not_persistence_confirmation
    ["", "Saving in progress", "Error: save failed\n[OK]\nCopy complete.\nSaving configuration is finished"].each do |output|
      each_device do |fixture|
        plan = fixture.device.plan_interface_descriptions { "planned" }
        fixture.save_output = output
        result = fixture.device.apply_interface_descriptions(plan, confirmed: true)
        assert result.failure?
        assert_equal :persistence_unconfirmed, result.error.code
        assert_equal :persist, result.error.phase
        assert_equal "planned", fixture.description
        assert_equal 1, fixture.transport.writes.count("#{fixture.sample.fetch(:save)}\n")
        assert_includes result.steps.map { |step| step.command.text }, "description planned"
      end
    end
  end

  def test_legacy_or_forged_command_sequences_are_rejected_before_changes
    each_device do |fixture|
      plan = fixture.device.plan_interface_descriptions { "planned" }
      legacy = plan.commands.reject { |command| fixture.device.config_commands.include?(command) }
      [legacy, plan.commands + ["reload"]].each do |commands|
        assert_raises(ArgumentError) { fixture.device.apply_interface_descriptions(plan.with(commands: commands), confirmed: true) }
        refute_includes fixture.transport.writes, "#{fixture.sample.fetch(:enter)}\n"
        refute_includes fixture.transport.writes, "#{fixture.sample.fetch(:save)}\n"
      end
    end
  end

  def test_panos_without_verified_candidate_isolation_is_read_only_before_io
    transport = ConnectorFake.new
    device = Net::Connector.build(:palo_alto, host: "192.0.2.1", username: "audit", transport: transport)
    assert device.supports?(:neighbors)
    assert device.supports?(:interface_descriptions)
    refute device.supports?(:interface_description_changes)
    error = assert_raises(Net::Connector::UnsupportedOperation) { device.plan_interface_descriptions }
    assert_equal :candidate_isolation_unavailable, error.code
    plan = Net::Connector::Topology::Plan.new(host: device.host, vendor: device.vendor,
                                                         evidence: {}, changes: [Object.new], commands: ["configure", "commit"])
    error = assert_raises(Net::Connector::UnsupportedOperation) { device.apply_interface_descriptions(plan, confirmed: true) }
    assert_equal :candidate_isolation_unavailable, error.code
    assert_equal 0, transport.opens
    assert_empty transport.writes
  ensure
    device&.close
  end

  def test_readback_must_use_the_approved_commands_before_saving
    each_device do |fixture|
      plan = fixture.device.plan_interface_descriptions { "planned" }
      collect = fixture.device.method(:running_config)
      fixture.device.define_singleton_method(:running_config) do
        result = collect.call
        next result unless fixture.description == "planned"

        steps = result.steps.map do |step|
          Net::Connector::CommandResult.new(command: step.command.with_text("unapproved readback"), output: step.output,
                                             prompt: step.prompt, duration: step.duration)
        end
        Net::Connector::Result.new(steps: steps, config: result.config)
      end
      result = fixture.device.apply_interface_descriptions(plan, confirmed: true)
      assert result.failure?
      assert_equal :verification_plan_changed, result.error.code
      refute_includes fixture.transport.writes, "#{fixture.sample.fetch(:save)}\n"
      assert_includes result.steps.map { |step| step.command.text }, "description planned"
    end
  end

  def test_lease_covers_the_gap_between_verified_state_and_persistence
    fixture = TopologyFixture.new(:cisco_ios)
    plan = fixture.device.plan_interface_descriptions { "planned" }
    collect = fixture.device.method(:running_config)
    checked, resume = Queue.new, Queue.new
    other_fiber = nil
    fixture.device.define_singleton_method(:running_config) do
      result = collect.call
      if fixture.description == "planned"
        other_fiber = Fiber.new { execute_command("other fiber") }.resume
        checked << true
        Timeout.timeout(3) { resume.pop }
      end
      result
    end
    applying = Thread.new { fixture.device.apply_interface_descriptions(plan, confirmed: true) }
    begin
      Timeout.timeout(3) { checked.pop }
      competing = fixture.device.execute_command("other thread")
      assert_instance_of Net::Connector::SessionBusy, competing.error
      assert_instance_of Net::Connector::SessionBusy, other_fiber.error
      refute_includes fixture.transport.writes, "copy running-config startup-config\n"
      refute_includes fixture.transport.writes, "other thread\n"
      refute_includes fixture.transport.writes, "other fiber\n"
    ensure
      resume << true
      applying.join(3) || applying.kill.join
    end
    assert applying.value.success?
    assert_equal 1, fixture.transport.writes.count("copy running-config startup-config\n")
  ensure
    fixture&.close
  end

  def test_uncertain_save_never_replays_on_a_new_connection_and_suppresses_raw_errors
    each_device do |fixture|
      plan = fixture.device.plan_interface_descriptions { "planned" }
      fixture.fail_on = fixture.sample.fetch(:save)
      result = fixture.device.apply_interface_descriptions(plan, confirmed: true)
      assert_equal :persistence_unconfirmed, result.error.code
      assert_equal "Net::Connector::CommandTimeout", result.error.underlying.type
      assert_equal "[REDACTED]", result.error.underlying.message
      assert_empty result.error.output
      assert_nil result.error.cause
      fixture.fail_on = nil
      fixture.transport.events << fixture.prompt
      assert fixture.device.execute_command("show status").success?
      assert_equal 2, fixture.transport.opens
      assert_equal 1, fixture.transport.writes.count("description planned\n")
      assert_equal 1, fixture.transport.writes.count("#{fixture.sample.fetch(:save)}\n")
    end
  end

  def test_log_cleanup_failure_after_confirmed_save_preserves_steps_and_releases_lease
    Dir.mktmpdir do |directory|
      fixture = TopologyFixture.new(:cisco_ios, log_file: File.join(directory, "session.log"), log_format: :raw)
      plan = fixture.device.plan_interface_descriptions { "planned" }
      topology = Net::Connector::Topology.new(fixture.device)
      strategy = topology.instance_variable_get(:@strategy)
      confirmed = strategy.method(:persistence_confirmed?)
      io = fixture.device.instance_variable_get(:@session).instance_variable_get(:@log).instance_variable_get(:@io)
      flush = io.method(:flush)
      fail_flush = false
      strategy.define_singleton_method(:persistence_confirmed?) do |result|
        confirmed.call(result).tap { |saved| fail_flush = saved }
      end
      io.define_singleton_method(:flush) { fail_flush ? raise(Errno::EIO) : flush.call }
      result = topology.apply_interface_descriptions(plan, confirmed: true)
      assert result.failure?
      assert_instance_of Net::Connector::LogError, result.error
      assert_equal plan.commands, (result.steps.map { |step| step.command.text })
      assert_equal "planned", fixture.description
      assert_equal 1, fixture.transport.writes.count("#{fixture.sample.fetch(:save)}\n")
      fail_flush = false
      assert fixture.device.execute_command("show status").success?
    ensure
      fail_flush = false
      fixture&.close
    end
  end
end
