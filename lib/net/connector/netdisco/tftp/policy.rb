# frozen_string_literal: true

require "ipaddr"
require_relative "../device/policy"
require_relative "../../../connector"
require_relative "../../device/tftp/target"
require_relative "root"

module Net
  module Connector
    module Netdisco
      module Tftp
        # 服务器、源和核验目录作为一个不可变设备策略解析，不能跨服务器借用核验证据。
        class Policy
          PlanningContext = Data.define(:host)
          private_constant :PlanningContext

          Options = Data.define(:server, :verification_root, :source_file, :source_interface, :vrf) do
            # 校验并冻结有效传输字段，确保设备间不共享可变策略。
            def initialize(**values)
              unless values.values.all? { |value| value.nil? || value.is_a?(String) }
                raise ArgumentError, "effective TFTP fields must be strings or nil"
              end
              super(**values.transform_values { |value| value&.dup&.freeze })
            end

            # 返回经校验的更新快照，未更新时沿用当前对象。
            def with(**attributes) = attributes.empty? ? self : self.class.new(**to_h.merge(attributes))
          end

          # 按厂商实际能力纯校验目标、源文件、接口和 VRF，不创建设备连接。
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

          # 预检默认服务器、设备覆盖和路由规则，确保不同服务器不共享核验根目录。
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
            @files = Device::Policy.new(source_files, vendors: %i[h3c h3c_wireless huawei]) do |value|
              TftpTarget.validate_source_file!(value) unless value.nil?
            end
            @interfaces = Device::Policy.new(source_interfaces, vendors: %i[h3c h3c_wireless radware centec]) do |value|
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
            @vrfs = Device::Policy.new(vrfs, vendors: %i[cisco_nxos hillstone]) do |value|
              unless value.nil? || (value.is_a?(String) && value.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/))
                raise ArgumentError, "vrfs contain an unsafe value"
              end
            end
            freeze
          end

          # 按精确主机与厂商解析一次有效传输策略，核验目录只取自该服务器。
          def for(host:, vendor:)
            server = @servers.fetch(address(host), @server)
            Options.new(server: server, verification_root: @roots[server],
                          source_file: @files.for(host: host, vendor: vendor),
                          source_interface: @interfaces.for(host: host, vendor: vendor),
                          vrf: @vrfs.for(host: host, vendor: vendor))
          end

          private

          # 规范化设备覆盖键为精确管理地址，拒绝网段和无效地址。
          def address(value)
            unless value.is_a?(String) && !value.empty? && !value.include?("/")
              raise ArgumentError, "TFTP host overrides require exact IP addresses"
            end
            IPAddr.new(value).to_s.freeze
          rescue IPAddr::Error
            raise ArgumentError, "TFTP host overrides require exact IP addresses", cause: nil
          end

          # 验证并规范化 TFTP 服务器 IP 或主机名，合并等价服务器键。
          def server_name(value)
            target = TftpTarget.new(host: value, path: "preflight.cfg")
            host = target.host.downcase
            begin
              IPAddr.new(host).to_s.freeze
            rescue IPAddr::Error
              host.freeze
            end
          end

          # 校验设备到服务器的映射，拒绝规范化后的重复设备键。
          def host_servers(values)
            raise ArgumentError, "TFTP servers must map devices to servers" unless values.is_a?(Hash)

            values.each_with_object({}) do |(host, server), result|
              key = address(host)
              raise ArgumentError, "duplicate normalized TFTP device override" if result.key?(key)

              result[key] = server_name(server)
            end.freeze
          end

          # 校验服务器与核验目录映射，拒绝规范化后的重复服务器。
          def server_roots(values)
            raise ArgumentError, "TFTP verification_roots must be a server mapping" unless values.is_a?(Hash)

            values.each_with_object({}) do |(server, root), result|
              key = server_name(server)
              raise ArgumentError, "duplicate normalized TFTP server" if result.key?(key)

              result[key] = root_path(root)
            end
          end

          # 区分 SSH 端点和本地目录，规范化路径并拒绝控制字符。
          def root_path(value)
            unless value.is_a?(String) && !value.empty? && !value.match?(/[\r\n\0]/)
              raise ArgumentError, "TFTP verification root must be a literal directory"
            end
            return Root.resolve(value) { |path| path } if Root.remote?(value)

            path = File.expand_path(value)
            (File.exist?(path) ? File.realpath(path) : path).freeze
          end
        end
      end
    end
  end
end
