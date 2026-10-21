# frozen_string_literal: true

require_relative "address_set"

module Net
  module Connector
    module Inventory
      # 只筛选已有设备，不识别厂商、不发现地址、不建立连接。
      class Selection
        Decision = Data.define(:reasons) do
          def initialize(reasons:)
            super(reasons: reasons.dup.freeze)
          end

          def selected? = reasons.empty?
        end

        def initialize(include_hosts: [], exclude_hosts: [], include_names: [], exclude_names: [],
                       include_vendors: [], exclude_vendors: [], include_models: [], exclude_models: [],
                       name_match: :contains, model_match: :contains)
          @include_hosts, @exclude_hosts = AddressSet.new(include_hosts), AddressSet.new(exclude_hosts)
          @names = [text_list(include_names), text_list(exclude_names), mode(name_match)].freeze
          @models = [text_list(include_models), text_list(exclude_models), mode(model_match)].freeze
          @vendors = [vendor_list(include_vendors), vendor_list(exclude_vendors)].freeze
          freeze
        end

        # 同字段包含取并集，不同字段取交集；排除优先，原因不携带设备正文。
        def evaluate(host:, vendor: nil, name: nil, model: nil)
          reasons = []
          if @exclude_hosts.include?(host)
            reasons << :host_excluded
          elsif !@include_hosts.empty? && !@include_hosts.include?(host)
            reasons << :host_not_included
          end
          vendor = vendor.to_s
          if @vendors.last.include?(vendor)
            reasons << :vendor_excluded
          elsif !@vendors.first.empty? && !@vendors.first.include?(vendor)
            reasons << :vendor_not_included
          end
          reasons << text_reason(:name, name, @names)
          reasons << text_reason(:model, model, @models)
          Decision.new(reasons: reasons.compact)
        end

        def selected?(host, vendor = nil, name: nil, model: nil)
          evaluate(host: host, vendor: vendor, name: name, model: model).selected?
        end

        def inspect = "#<#{self.class}>"
        alias to_s inspect

        private

        def mode(value)
          unless (value.is_a?(String) || value.is_a?(Symbol)) && %w[contains prefix glob].include?(value.to_s)
            raise ArgumentError, "match mode must be contains, prefix or glob"
          end
          value.to_sym
        end

        def text_list(values)
          unless values.is_a?(Array) && values.all? { |v| v.is_a?(String) && v.valid_encoding? && !v.strip.empty? && !/[\x00-\x1f\x7f]/.match?(v) }
            raise ArgumentError, "filters must be arrays of nonempty text"
          end
          values.map { |v| v.downcase.freeze }.uniq.freeze
        end

        def vendor_list(values)
          unless values.is_a?(Array) && values.all? { |v| v.is_a?(String) || v.is_a?(Symbol) }
            raise ArgumentError, "vendors must be strings or symbols"
          end
          text_list(values.map(&:to_s))
        end

        def text_reason(field, value, rules)
          includes, excludes, match = rules
          value = value&.to_s&.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")&.downcase
          return :"#{field}_excluded" if value && excludes.any? { |pattern| matches?(pattern, value, match) }
          return :"#{field}_not_included" if !includes.empty? && (!value || includes.none? { |pattern| matches?(pattern, value, match) })

          nil
        end

        def matches?(pattern, value, match)
          case match
          when :contains then value.include?(pattern)
          when :prefix then value.start_with?(pattern)
          when :glob then File.fnmatch?(pattern, value)
          end
        end
      end
    end
  end
end
