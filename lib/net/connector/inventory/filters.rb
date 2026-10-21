# frozen_string_literal: true

require "optparse"
require_relative "selection"

module Net
  module Connector
    module Inventory
      # 脚本共享筛选词汇和参数；配置来源及优先级仍由宿主决定。
      module Filters
        LISTS = {
          "hosts" => :include_hosts, "exclude_hosts" => :exclude_hosts,
          "names" => :include_names, "exclude_names" => :exclude_names,
          "vendors" => :include_vendors, "exclude_vendors" => :exclude_vendors,
          "models" => :include_models, "exclude_models" => :exclude_models
        }.freeze
        MODES = %w[name_match model_match].freeze
        FIELDS = (LISTS.keys + MODES).freeze
        FLAGS = {
          "--hosts LIST" => "hosts", "--exclude-hosts LIST" => "exclude_hosts",
          "--name LIST" => "names", "--exclude-name LIST" => "exclude_names",
          "--vendor LIST" => "vendors", "--exclude-vendor LIST" => "exclude_vendors",
          "--model LIST" => "models", "--exclude-model LIST" => "exclude_models"
        }.freeze

        def self.selection(values)
          arguments = LISTS.to_h { |key, argument| [argument, values.fetch(key, [])] }
          MODES.each { |key| arguments[key.to_sym] = values.fetch(key, :contains) }
          Selection.new(**arguments)
        end

        # 每个回调只交付本次参数；追加或覆盖由配置适配器显式处理。
        def self.add_options(parser, single_host: true, &accept)
          flags = single_host ? {"--host IP" => "hosts"}.merge(FLAGS) : FLAGS
          flags.each do |flag, key|
            parser.on(flag, "筛选已有清单，同类条件取并集，排除优先") do |value|
              items = value.split(",", -1).map(&:strip)
              raise OptionParser::InvalidArgument, "filter list contains empty items" if items.empty? || items.any?(&:empty?)

              accept.call(key, items)
            end
          end
          MODES.each do |key|
            parser.on("--#{key.tr("_", "-")} MODE", %w[contains prefix glob], "匹配方式 contains / prefix / glob") { |value| accept.call(key, value) }
          end
        end
      end
    end
  end
end
