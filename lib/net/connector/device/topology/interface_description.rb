# frozen_string_literal: true

require_relative "interface_name"

module Net
  module Connector
    class Topology
      # 描述文本与常见接口视图命令的纯构造方法，不连接或修改设备。
      module InterfaceDescription
        # 将邻居名称和接口拼成默认描述；统一邻居接口简称，原始发现记录保持不变。
        def self.format(neighbor, abbreviate: true, lowercase: false)
          port = if abbreviate
                   InterfaceName.short(neighbor.neighbor_interface, lowercase: lowercase)
                 else
                   lowercase ? neighbor.neighbor_interface.downcase : neighbor.neighbor_interface
                 end
          validate!("To_#{neighbor.neighbor_name.tr(" ", "_")}_#{port.tr(" ", "_")}")
        end

        # 保留语义相同的旧描述；只归一末尾已知接口别名和大小写，不模糊匹配名称或端口编号。
        # 未识别端口只允许忽略大小写；速率、子接口和拆分通道仍属于不同身份。
        def self.equivalent?(current, expected)
          return true if current.casecmp?(expected)

          old_prefix, separator, old_port = current.rpartition("_")
          new_prefix, new_separator, new_port = expected.rpartition("_")
          return false if separator.empty? || new_separator.empty? || !old_prefix.casecmp?(new_prefix)
          return false unless InterfaceName::RULES.any? { |pattern,| pattern.match?(old_port) } &&
                              InterfaceName::RULES.any? { |pattern,| pattern.match?(new_port) }

          InterfaceName.key(old_port) == InterfaceName.key(new_port)
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
          return value if value.is_a?(String) && value.match?(/\A[A-Za-z][A-Za-z0-9.:\/-]*\z/)

          raise ArgumentError, "neighbor interface name is unsafe"
        end
      end
    end
  end
end
