# frozen_string_literal: true

require_relative "fake_transport"

# 合成拓扑对话，型号/固件均 unknown；视图转换与保存完成行的来源见 fixtures/topology/README.md。
# 只驱动 ConnectorFake，不连接设备，不模拟存储介质的真实持久性。
class TopologyFixture
  SAMPLES = {
    cisco_ios: { interface: "GigabitEthernet1/0/1", enter: "configure terminal", leave: "end", save: "copy running-config startup-config",
                 neighbor: "Device ID: peer\nInterface: GigabitEthernet1/0/1, Port ID (outgoing port): GigabitEthernet1/0/2\n",
                 collect: "show running-config", ending: "!\nend", saved: "Building configuration...\n[OK]" },
    cisco_nxos: { interface: "Ethernet1/1", enter: "configure terminal", leave: "end", save: "copy run start",
                  neighbor: "Device ID: peer\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n",
                  collect: "show running-config", ending: "!\nend", saved: "[########################################] 100%\nCopy complete." },
    h3c: { interface: "GigabitEthernet1/0/1", enter: "system-view", leave: "return", save: "save force",
           neighbor: "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 GE1/0/2 peer\n",
           collect: "dis cur", ending: "#", saved: "Validating file. Please wait....\nSaved the current configuration to mainboard device successfully." },
    hillstone: { interface: "ethernet0/1", enter: "configure", leave: "exit", save: "save all",
                 neighbor: "System Name Local Interface Chassis ID Port ID\npeer ethernet0/1 7425.8ae4.4f4c ethernet0/2\nTotal lldp neighbor number: 1.\n",
                 collect: "show configuration running", ending: "exit", saved: "Building configuration.\nSaving configuration is finished" }
  }.freeze

  attr_reader :transport, :device, :sample, :observed
  attr_accessor :description, :mismatch, :fail_on, :save_output, :partial_readback, :on_command

  def initialize(vendor)
    @sample = SAMPLES.fetch(vendor)
    @vendor = vendor
    @mode = :exec
    @description = "original"
    @save_output = sample.fetch(:saved)
    @observed = []
    @transport = ConnectorFake.new(prompt)
    @device = Net::Connector.build(vendor, host: "192.0.2.1", username: "audit", transport: transport)
    transport.on_write = method(:write)
  end

  def prompt
    return @mode == :exec ? "<switch>" : "[switch#{@mode == :interface ? "-interface" : ""}]" if @vendor == :h3c

    { exec: "switch#", config: "switch(config)#", interface: "switch(config-if)#" }.fetch(@mode)
  end

  def configuration
    output = "interface #{sample.fetch(:interface)}\n description #{description}\n#{sample.fetch(:ending)}\n"
    output += "interface malformed extra fields\n description ignored\n" if partial_readback && description == "planned"
    output
  end

  def write(bytes, _timeout)
    command = bytes.strip
    observed << [command, @mode]
    on_command&.call(command)
    if command == fail_on
      transport.events << :timeout
      return
    end
    body = if command == device.profile.topology_strategy.new(device).neighbor_command
             sample.fetch(:neighbor)
           elsif command == sample.fetch(:collect)
             configuration
           elsif command == sample.fetch(:save)
             save_output
           else
             update(command)
             ""
           end
    transport.events << "#{command}\r\n#{body.gsub("\n", "\r\n")}\r\n#{prompt}"
  end

  def update(command)
    if command == sample.fetch(:enter)
      @mode = :config
    elsif command.start_with?("interface ")
      @mode = :interface
    elsif command.start_with?("description ")
      @description = command.delete_prefix("description ") unless mismatch
    elsif %w[exit quit].include?(command)
      @mode = @mode == :interface ? :config : :exec
    elsif command == sample.fetch(:leave)
      @mode = :exec
    end
  end

  def close = device.close
end
