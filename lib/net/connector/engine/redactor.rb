# frozen_string_literal: true

require "expect/redactor"

module Net
  module Connector
    # 管理连接器的秘密作用域和输出敏感性；字节过滤统一委托给 expect-pty。
    class Redactor
      MASK = "[REDACTED]".b.freeze

      # 保存初始凭据，并建立第一版脱敏词表。
      def initialize(*secrets)
        unless Expect.constants(false).include?(:Redactor) && Expect::Redactor.respond_to?(:redact)
          raise LoadError, "net-connector requires expect-pty with the public Expect::Redactor API"
        end

        @configured = secrets.compact.map(&:b).map(&:freeze).freeze
        reset
      end

      # 重置动态词表，同时保留配置中的固定凭据。
      def reset
        @secrets = []
        @patterns = nil
        @scoped = false
        @sensitive = false
        @output_sensitive = false
        @configured.each { |secret| remember(secret) }
      end

      # 临时命令响应在错误归一化期间保留，离开作用域后不进入长期会话。
      def with_scope(reuse: false)
        return yield if reuse && @scoped

        previous = @secrets
        previous_patterns = @patterns
        previous_scoped = @scoped
        previous_sensitive = @sensitive
        previous_output_sensitive = @output_sensitive
        @secrets = previous.dup
        @scoped = true
        begin
          yield
        ensure
          @secrets = previous
          @patterns = previous_patterns
          @scoped = previous_scoped
          @sensitive = previous_sensitive
          @output_sensitive = previous_output_sensitive
        end
      end

      # 敏感命令和交互的异常可能只引用秘密的一部分，不能只依赖完整词匹配。
      def sensitive! = @sensitive = true

      # 判断当前脱敏范围是否包含敏感交互。
      def sensitive? = @sensitive

      # 输出敏感时不把正文加入词表；只在当前范围内屏蔽日志和任意错误正文。
      def output_sensitive!
        @output_sensitive = true
        sensitive!
      end

      # 后续查询继承输出边界，即使查询命令本身没有敏感标记。
      def output_sensitive? = @output_sensitive

      # 只维护当前作用域的注册词；匹配次序和重叠区间交给共享过滤器。
      def remember(secret)
        return if secret.nil? || secret.empty?

        bytes = secret.b
        return if @secrets.include?(bytes)

        @secrets << bytes.freeze
        @patterns = nil
      end

      # 一次性诊断不共享流状态；原标记作为不透明区间，避免再次展开它。
      def call(text)
        Expect::Redactor.redact(text.to_s.b, patterns, replacement: MASK)
      end

      # 每个日志目标独占过滤流，跨分片尾部和重叠掩码由依赖库维护。
      def stream
        Expect::Redactor.new(patterns, replacement: MASK)
      end

      # 临时范围恢复时，日志流可以同步恢复注册词表，不缓存配置正文。
      def patterns
        @patterns ||= (@secrets.empty? ? [] : (@secrets + [MASK]).uniq).freeze
      end

      # 返回脱敏器类型摘要。
      def inspect = "#<#{self.class}>"
    end
  end
end
