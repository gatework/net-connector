# frozen_string_literal: true

require "ipaddr"
require_relative "../vendor_device_policy"
require_relative "../../../connector"
require_relative "../../device/tftp/target"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 服务器、源和核验目录作为一个不可变设备策略解析，不能跨服务器借用核验证据。
        class Policy
          PlanningContext = Data.define(:host)
          private_constant :PlanningContext

          Options = Data.define(:server, :verification_root, :source_file, :source_interface, :vrf) do
            def initialize(**values)
              unless values.values.all? { |value| value.nil? || value.is_a?(String) }
                raise ArgumentError, "effective TFTP fields must be strings or nil"
              end
              super(**values.transform_values { |value| value&.dup&.freeze })
            end

            def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
          end

          def self.validate_options!(transfer, host:, vendor:, path: nil)
            raise ArgumentError, "invalid TFTP options" unless transfer.instance_of?(Options)

            strategy_class = Net::Connector.vendor_class(vendor).profile.tftp_strategy
            raise ArgumentError, "device does not support native TFTP" unless strategy_class

            target = TftpTarget.new(host: transfer.server || "preflight.invalid", path: path || strategy_class.filename(host))
            context = PlanningContext.new(host: host)
            strategy = strategy_class.new(context)
            strategy.validate_options!(target, source_file: transfer.source_file, vrf: transfer.vrf)
            unless transfer.source_interface.nil?
              unless strategy.respond_to?(:validate_source_interface!)
                raise ArgumentError, "source_interface is not supported by this TFTP strategy"
              end
              strategy.validate_source_interface!(target, source_interface: transfer.source_interface)
            end
            if transfer.vrf && !transfer.vrf.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/)
              raise ArgumentError, "VRF must be a single safe name"
            end
            transfer
          end

          def initialize(server: nil, servers: {}, verification_root: nil, verification_roots: {},
                         source_files: {}, source_interfaces: {}, vrfs: {})
            @server = server && server_name(server)
            @servers = host_servers(servers)
            @roots = server_roots(verification_roots)
            root_path(verification_root) if verification_root
            if verification_root && @server
              root = root_path(verification_root)
              if @roots.key?(@server) && @roots[@server] != root
                raise ArgumentError, "conflicting verification roots for the default TFTP server"
              end
              @roots = @roots.merge(@server => root)
            end
            if @roots.values.uniq.size != @roots.size
              raise ArgumentError, "distinct TFTP servers cannot share a verification root"
            end
            @roots.freeze
            @files = VendorDevicePolicy.new(source_files, vendors: %i[h3c h3c_wireless huawei]) do |value|
              TftpTarget.validate_source_file!(value) unless value.nil?
            end
            @interfaces = VendorDevicePolicy.new(source_interfaces, vendors: %i[h3c h3c_wireless radware]) do |value|
              unless value.nil? || (value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z0-9_.\/: -]*\z/) && !value.end_with?(" "))
                raise ArgumentError, "source_interfaces contain an unsafe value"
              end
            end
            target = TftpTarget.new(host: "preflight.invalid", path: "preflight.cfg")
            @interfaces.to_h.each do |vendor, entry|
              strategy = Net::Connector.vendor_class(vendor).profile.tftp_strategy.new(PlanningContext.new(host: "192.0.2.1"))
              [entry[:default], *entry[:hosts].values].each do |value|
                strategy.validate_source_interface!(target, source_interface: value)
              end
            end
            @vrfs = VendorDevicePolicy.new(vrfs, vendors: %i[cisco_nxos hillstone]) do |value|
              unless value.nil? || (value.is_a?(String) && value.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/))
                raise ArgumentError, "vrfs contain an unsafe value"
              end
            end
            freeze
          end

          def for(host:, vendor:)
            server = @servers.fetch(address(host), @server)
            Options.new(server: server, verification_root: @roots[server],
                          source_file: @files.for(host: host, vendor: vendor),
                          source_interface: @interfaces.for(host: host, vendor: vendor),
                          vrf: @vrfs.for(host: host, vendor: vendor))
          end

          private

          def address(value)
            unless value.is_a?(String) && !value.empty? && !value.include?("/")
              raise ArgumentError, "TFTP host overrides require exact IP addresses"
            end
            IPAddr.new(value).to_s.freeze
          rescue IPAddr::Error
            raise ArgumentError, "TFTP host overrides require exact IP addresses", cause: nil
          end

          def server_name(value)
            target = TftpTarget.new(host: value, path: "preflight.cfg")
            host = target.host.downcase
            begin
              IPAddr.new(host).to_s.freeze
            rescue IPAddr::Error
              host.freeze
            end
          end

          def host_servers(values)
            raise ArgumentError, "TFTP servers must map devices to servers" unless values.is_a?(Hash)

            values.each_with_object({}) do |(host, server), result|
              key = address(host)
              raise ArgumentError, "duplicate normalized TFTP device override" if result.key?(key)

              result[key] = server_name(server)
            end.freeze
          end

          def server_roots(values)
            raise ArgumentError, "TFTP verification_roots must be a server mapping" unless values.is_a?(Hash)

            values.each_with_object({}) do |(server, root), result|
              key = server_name(server)
              raise ArgumentError, "duplicate normalized TFTP server" if result.key?(key)

              result[key] = root_path(root)
            end
          end

          def root_path(value)
            unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n\0]/)
              raise ArgumentError, "TFTP verification root must be a literal directory"
            end
            path = File.expand_path(value)
            (File.exist?(path) ? File.realpath(path) : path).freeze
          end
        end
      end
    end
  end
end
