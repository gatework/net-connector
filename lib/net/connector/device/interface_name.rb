# frozen_string_literal: true

module Net
  module Connector
    # 接口身份匹配与描述展示共用名称规则；展示简称不能直接用作下发命令。
    module InterfaceName
      RULES = [
        [/\A(?:xge|ten-gigabitethernet|tengigabitethernet|te)(?=\d)/i, "tengigabitethernet", "Te"],
        [/\A(?:gigabitethernet|ge|gi)(?=\d)/i, "gigabitethernet", "Gi"],
        [/\A(?:fastethernet|fa)(?=\d)/i, "fastethernet", "Fa"],
        [/\A(?:ethernet|eth)(?=\d)/i, "ethernet", "Eth"],
        [/\A(?:port-channel|po)(?=\d)/i, "port-channel", "Po"]
      ].map(&:freeze).freeze

      # 用于本机邻居表与配置的关联；保留已有证据键的拼写契约。
      def self.key(name)
        rule = RULES.find { |pattern, _key, _short| pattern.match?(name) }
        rule ? name.sub(rule.first, rule[1]).downcase : name.downcase
      end

      # 仅缩短已识别的前缀，保留端口、子接口编号及未知命名。
      # 默认延续输入的大写、小写或首字母大写形式；统一小写由调用方选择。
      def self.short(name, lowercase: false)
        rule = RULES.find { |pattern, _key, _short| pattern.match?(name) }
        formatted = if rule
                      name.sub(rule.first) do |prefix|
                        abbreviation = rule.last
                        if prefix == prefix.downcase
                          abbreviation.downcase
                        elsif prefix == prefix.upcase
                          abbreviation.upcase
                        elsif prefix.casecmp?(abbreviation)
                          prefix
                        else
                          abbreviation
                        end
                      end
                    else
                      name.dup
                    end
        lowercase ? formatted.downcase : formatted
      end

      # 保留现有配置视图展开规则；厂商策略可覆盖不适用的名称。
      def self.configuration(name)
        name.sub(/\AXGE(?=\d)/i, "Ten-GigabitEthernet")
            .sub(/\AGE(?=\d)/i, "GigabitEthernet")
            .sub(/\AGi(?=\d)/i, "GigabitEthernet")
            .sub(/\ATe(?=\d)/i, "TenGigabitEthernet")
            .sub(/\AFa(?=\d)/i, "FastEthernet")
            .sub(/\AEth(?=\d)/i, "Ethernet")
            .sub(/\APo(?=\d)/i, "port-channel")
      end
    end
  end
end
