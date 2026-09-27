# frozen_string_literal: true

require_relative "interface_name"

module Net
  module Connector
    class Topology
      # 描述文本与常见接口视图命令的纯构造方法，不连接或修改设备。
      module InterfaceDescription
        # 将邻居名称和接口拼成默认描述；只缩写邻居接口，保留原始大小写。
        def self.format(neighbor, abbreviate: true, lowercase: false)
          port = if abbreviate
                   InterfaceName.short(neighbor.neighbor_interface, lowercase: lowercase)
                 else
                   lowercase ? neighbor.neighbor_interface.downcase : neighbor.neighbor_interface
                 end
          validate!("To #{neighbor.neighbor_name} #{port}")
        end

        # 生成进入接口、设置描述和退出视图的命令，不执行设备操作。
        def self.commands(interface:, description:, leave: "exit")
          validate_interface!(interface)
          validate!(description)
          raise ArgumentError, "interface exit must be exit or quit" unless %w[exit quit].include?(leave)

          ["interface #{interface}", "description #{description}", leave]
        end

        # 共享的输入约束同样适用于 PAN-OS 的独立命令语法。
        def self.validate!(value)
          return value if value.is_a?(String) && value.bytesize.between?(1, 80) &&
                          value.match?(/\A[\p{Alnum}_.: \/-]+\z/u)

          raise ArgumentError, "description must be 1-80 bytes of plain interface text"
        end

        # 拒绝可能把描述命令拆成多条命令的不安全接口名。
        def self.validate_interface!(value)
          return value if value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z0-9.\/-]*\z/)

          raise ArgumentError, "neighbor interface name is unsafe"
        end
      end
    end
  end
end
