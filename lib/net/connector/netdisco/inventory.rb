# frozen_string_literal: true

module Net
  module Connector
    module Netdisco
      # HTTP、PostgreSQL 与缓存共用清单字段、错误和资源范围，不依赖具体来源。
      module Inventory
        class Error < StandardError
          # 读取清单错误的稳定分类码。
          attr_reader :code

          # 保存清单错误消息及稳定错误码，供上层分类处理。
          def initialize(message = nil, code: :inventory_error)
            @code = code
            super(message)
          end
        end

        class Timeout < Error
          # 构造总清单预算已耗尽的统一超时错误。
          def initialize(_message = nil)
            super("Netdisco inventory exceeded inventory_timeout", code: :inventory_timeout)
          end
        end

        FIELDS = %w[ip name dns vendor os model os_ver serial].freeze
        DEFAULT_MAX_PAGES = 10_000
        DEFAULTS = { page_size: 500, max_pages: DEFAULT_MAX_PAGES, max_response_bytes: 16 * 1024 * 1024,
                     max_inventory_bytes: 128 * 1024 * 1024, max_devices: 100_000,
                     inventory_timeout: 300 }.freeze

        # 预检、HTTP 与数据库使用同一套清单预算校验。
        def self.options(**values)
          raise ArgumentError, "unknown inventory options" unless (values.keys - DEFAULTS.keys).empty?

          options = DEFAULTS.merge(values)
          %i[page_size max_pages max_response_bytes max_inventory_bytes max_devices].each do |name|
            value = options.fetch(name)
            raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
          end
          duration = options.fetch(:inventory_timeout)
          unless duration.is_a?(Numeric) && duration.real? && duration.finite? && duration.positive? && duration.to_f.finite?
            raise ArgumentError, "inventory_timeout must be a positive finite number"
          end
          options.freeze
        end
      end
    end
  end
end
