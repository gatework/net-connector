# frozen_string_literal: true

module Net
  module Connector
    # 保存命令及能力入口，响应语义由通用执行器负责。
    module SaveConfig
      # 执行厂商保存配置命令；不支持时返回显式失败结果。
      def save_config
        if save_commands.empty?
          return Result.new(error: @session.build_error(UnsupportedOperation, "saving configuration is not supported",
                                                  phase: :save))
        end

        execute_script(save_commands)
      end

      # 返回保存配置命令；空数组表示设备不支持保存。
      def save_commands = profile.save_commands
    end
  end
end
