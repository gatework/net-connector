# frozen_string_literal: true

require "ipaddr"
require_relative "../operations/saved_config"

module Net
  module Connector
    module Netdisco
      # 仅保存清单元数据，设备凭据由调用方管理。
      Device = Data.define(:host, :source_ip, :name, :vendor, :source_vendor, :model, :os, :os_version, :serial, :issue) do
        # 清单行来自可变的外部数据；设备快照不共享其中的字符串。
        def initialize(*values, **attributes)
          frozen_values = values.map { |value| value.is_a?(String) ? value.dup.freeze : value }
          frozen_attributes = attributes.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }
          super(*frozen_values, **frozen_attributes)
        end

        # 将 Netdisco 清单记录转换为可规划的设备对象。
        def self.from_row(row, rules:)
          valid = row.is_a?(Hash) && row["ip"].is_a?(String) && !row["ip"].empty? &&
                  Client::FIELDS.drop(1).all? { |field| row[field].nil? || row[field].is_a?(String) }
          raise Client::Error, "Netdisco returned an invalid device inventory" unless valid

          source_ip = row.fetch("ip")
          host = nil
          issue = nil
          begin
            raise IPAddr::InvalidAddressError, "address includes a prefix" if source_ip.include?("/")

            host = IPAddr.new(source_ip).to_s
          rescue IPAddr::Error
            issue = :invalid_address
          end
          vendor = rules.resolve(row)
          issue ||= :unsupported_vendor unless vendor
          issue ||= :filtered unless rules.selected?(host, vendor)
          name = [row["name"], row["dns"]].find { |value| value && !value.strip.empty? }
          new(host: host, source_ip: source_ip, name: name&.strip, vendor: vendor,
              source_vendor: row["vendor"], model: row["model"], os: row["os"],
              os_version: row["os_ver"], serial: row["serial"], issue: issue)
        end

        # 判断设备是否满足备份选择条件。
        def ready? = issue.nil?

        # 生成不随名称或厂商信息改变的本地文本文件名。
        def backup_filename = Operations::SavedConfig.filename(host)

        # 生成设备 CLI 可用的 ASCII 远端文件名。
        def tftp_filename
          label = name.to_s.encode(Encoding::US_ASCII, invalid: :replace, undef: :replace, replace: "-")
                      .gsub(/[^A-Za-z0-9._-]+/, "-").byteslice(0, 180)
                      .gsub(/\A[._-]+|[._-]+\z/, "")
          label = vendor&.to_s || "device" if label.empty?
          strategy = Net::Connector.vendor_class(vendor).profile.tftp_strategy if vendor
          # 旧版自定义策略只需实现实例接口，缺少命名接口时沿用通用 cfg 名称。
          strategy = Operations::Tftp::Strategy unless strategy.respond_to?(:filename)
          TftpTarget.validate_path!(strategy.filename(host, label: label))
        end

        # 按厂商及设备地址实例化连接器。
        def connector(**settings)
          raise ArgumentError, "device is not ready: #{issue}" unless ready?
          raise ArgumentError, "host cannot be overridden" if settings.key?(:host)

          Net::Connector.build(vendor, host: host, **settings)
        end
      end
    end
  end
end
