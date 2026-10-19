# frozen_string_literal: true

module Net
  module Connector
    class Topology
      # 接口身份匹配与描述展示共用名称规则；展示简称不能直接用作下发命令。
      module InterfaceName
        RULES = [
          [/\A(?:bridge-aggregation|bagg)(?=\d)/i, "bridge-aggregation", "BAGG"],
          [/\A(?:route-aggregation|ragg)(?=\d)/i, "route-aggregation", "RAGG"],
          [/\A(?:aggregate|agg)(?=\d)/i, "aggregate", "Agg"],
          [/\A(?:hundredgigabitethernet|hundredgige|hge|100ge|hu)(?=\d)/i, "hundredgigabitethernet", "Hu"],
          [/\A(?:fortygigabitethernet|fortygige|fge|40ge|fo)(?=\d)/i, "fortygigabitethernet", "Fo"],
          [/\A(?:twenty-?fivegigabitethernet|twenty-?fivegige|wge|25ge|twe)(?=\d)/i, "twentyfivegigabitethernet", "Twe"],
          [/\A(?:xge|10ge|xgigabitethernet|ten-gigabitethernet|tengigabitethernet|ten-?gige|xethernet|xe|te)(?=\d)/i, "tengigabitethernet", "Te"],
          [/\A(?:smartrate-ethernet|se)(?=\d)/i, "smartrate-ethernet", "SE"],
          [/\A(?:gigabitethernet|ge|gi|g)(?=\d)/i, "gigabitethernet", "Gi"],
          [/\A(?:fastethernet|fa)(?=\d)/i, "fastethernet", "Fa"],
          [/\A(?:ethernet|eth)(?=\d)/i, "ethernet", "Eth"],
          [/\A(?:port-channel|po)(?=\d)/i, "port-channel", "Po"]
        ].map(&:freeze).freeze

        # 用于本机邻居表与配置的关联；同类别名归一，不混淆速率、聚合类型或端口编号。
        def self.key(name)
          rule = RULES.find { |pattern, _key, _short| pattern.match?(name) }
          rule ? name.sub(rule.first, rule[1]).downcase : name.downcase
        end

        # 仅缩短已识别的前缀，保留端口、子接口编号及未知命名。
        # 厂商全称、缩写与大小写统一展示；原始身份和本机下发拼写不参与替换。
        def self.short(name, lowercase: false)
          rule = RULES.find { |pattern, _key, _short| pattern.match?(name) }
          formatted = rule ? name.sub(rule.first, rule.last) : name.dup
          lowercase ? formatted.downcase : formatted
        end

        # 保留现有配置视图展开规则；厂商策略可覆盖不适用的名称。
        def self.configuration(name)
          name.sub(/\ASE(?=\d)/i, "Smartrate-Ethernet")
              .sub(/\AXGE(?=\d)/i, "Ten-GigabitEthernet")
              .sub(/\AGE(?=\d)/i, "GigabitEthernet")
              .sub(/\A(?:Gi|G)(?=\d)/i, "GigabitEthernet")
              .sub(/\ATe(?=\d)/i, "TenGigabitEthernet")
              .sub(/\AFa(?=\d)/i, "FastEthernet")
              .sub(/\AEth(?=\d)/i, "Ethernet")
              .sub(/\APo(?=\d)/i, "port-channel")
        end
      end
    end
  end
end
