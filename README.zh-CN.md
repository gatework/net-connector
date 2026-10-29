# net-connector

[English](README.md) | [简体中文](README.zh-CN.md)

通过 SSH 或 Telnet 操作网络设备的 Ruby 库。支持配置采集、私有备份、交互脚本、TextFSM 解析，以及基于 Netdisco 清单的批量备份。

需要 Ruby 3.4+、expect-pty 0.9.6+、ctx_cli 0.4.x、TextFSM 0.5.1+ 和 POSIX 系统。SSH 使用本机 OpenSSH；Telnet 需要本机安装 `telnet` 并显式配置。

## 安装

```sh
gem install net-connector
```

## 快速开始

先创建并保护备份目录、登记设备 SSH 主机密钥，再通过环境变量提供凭据。

```ruby
require "net/connector"

Net::Connector.open(:cisco_ios,
  host: "192.0.2.10", username: ENV.fetch("NC_DEVICE_USERNAME"),
  password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  backup = device.backup(path: "/var/backups/network/router.cfg")
  puts "#{backup.bytes} bytes, SHA-256 #{backup.sha256}"
end
```

代码块退出时关闭会话。备份通过私有文件原子替换，采集失败保留旧备份，设备命令不会自动重放。返回的配置和命令输出仍是敏感数据。

## 支持的设备

H3C Comware 及无线控制器、Cisco IOS/IOS XE 与 NX-OS、华为、山石 StoneOS、Radware Alteon 、Palo Alto PAN-OS、天融信 TopOS、Fortinet FortiOS 和 Juniper Junos OS。各厂商能力不同，详见[设备操作指南](docs/usage.zh-CN.md#支持的设备)。合成测试不代表所有固件均已现场验证。

## 批量备份

```sh
net-backup --config config.yml --show-config
net-backup --config config.yml --plan
net-backup --config config.yml
```

从 [backup.example.yml](examples/backup.example.yml) 或 [inventory.yml](examples/inventory.yml) 开始配置。清单与设备凭据放在环境变量中，YAML 只保存非敏感设置。HTTP/PostgreSQL 清单、成功策略、TFTP 核验和批量示例见 [Netdisco 指南](docs/netdisco.zh-CN.md)。

## 文档

| 主题 | English | 简体中文 |
| --- | --- | --- |
| 设备操作、解析、拓扑与日志 | [Device guide](docs/usage.md) | [设备操作](docs/usage.zh-CN.md) |
| 清单、配置、CLI 与批量备份 | [Netdisco guide](docs/netdisco.md) | [清单与批量备份](docs/netdisco.zh-CN.md) |

详细参考：[架构](docs/architecture.md)、[验证](docs/VERIFICATION.md)、[发布](docs/RELEASING.md)和[示例](examples/README.md)。

## 开发

```sh
bundle install
script/ci
```

门禁执行敏感数据扫描、Ruby 与工作流检查、测试、本地 PTY 基准及隔离安装验证。参与开发见 [CONTRIBUTING](CONTRIBUTING.md)，漏洞报告见 [SECURITY](SECURITY.md)，版本变化见[更新记录](CHANGELOG.md)。问题和 PR 可使用中文或英文。

采用 [MIT](LICENSE) 许可。
