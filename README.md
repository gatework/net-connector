# net-connector

[English](README.md) | [简体中文](README.zh-CN.md)

Ruby sessions for network device CLIs over SSH or Telnet. Collect configurations, save private backups, run interactive scripts, parse output with TextFSM, and back up fleets from Netdisco inventories.

Requires Ruby 3.4+, expect-pty 0.9.4+ and a POSIX system. SSH uses local OpenSSH; Telnet requires a local `telnet` executable and explicit configuration.

## Install

```sh
gem install net-connector
```

## Quick start

Create and protect the backup directory, register the device's SSH host key, and provide credentials through your environment.

```ruby
require "net/connector"

Net::Connector.open(:cisco_ios,
  host: "192.0.2.10", username: ENV.fetch("NC_DEVICE_USERNAME"),
  password: ENV.fetch("NC_DEVICE_PASSWORD")) do |device|
  backup = device.backup(path: "/var/backups/network/router.cfg")
  puts "#{backup.bytes} bytes, SHA-256 #{backup.sha256}"
end
```

The block closes the session on exit. Backups use private files and atomic replacement; a failed collection preserves the previous backup. Commands are never automatically replayed. Returned configurations and command output remain sensitive data.

## Supported devices

H3C Comware and wireless controllers, Cisco IOS/IOS XE and NX-OS, Huawei, Hillstone StoneOS, Radware Alteon, Palo Alto PAN-OS, Topsec TopOS, Fortinet FortiOS, and Juniper Junos OS. Capabilities vary by vendor; see the [device guide](docs/usage.md#supported-devices). Synthetic tests do not establish support for every firmware version.

## Fleet backups

```sh
net-backup --config config.yml --show-config
net-backup --config config.yml --plan
net-backup --config config.yml
```

Start with [backup.example.yml](examples/backup.example.yml) or [inventory.yml](examples/inventory.yml). Configure inventory and device credentials in the environment; YAML contains non-sensitive settings. See the [Netdisco guide](docs/netdisco.md) for HTTP/PostgreSQL inventories, success policies, TFTP verification, and batch examples.

## Documentation

| Topic | English | 简体中文 |
| --- | --- | --- |
| Device operations, parsing, topology, logging | [Device guide](docs/usage.md) | [设备操作](docs/usage.zh-CN.md) |
| Inventory, configuration, CLI, fleet backups | [Netdisco guide](docs/netdisco.md) | [清单与批量备份](docs/netdisco.zh-CN.md) |

Detailed references: [architecture](docs/architecture.md), [verification](docs/VERIFICATION.md), [releasing](docs/RELEASING.md), and [examples](examples/README.md) (Chinese).

## Development

```sh
bundle install
script/ci
```

The gate scans secrets, lints Ruby and workflows, runs tests and local PTY benchmarks, and verifies isolated gem installs. See [CONTRIBUTING](CONTRIBUTING.md), [security reporting](SECURITY.md), and the [changelog](CHANGELOG.md). Issues and pull requests may be written in English or Chinese.

Licensed under [MIT](LICENSE).

## ctx_cli 公共入口

宿主配置文件读取、私有文件初始化、公共参数与终端交互由 ctx_cli 维护。原 `Net::Connector::Config`、配置路径、优先级和 backup/TFTP/topology 策略继续保留。源码联调使用 `CTX_CLI_PATH=../ctx_cli`；隔离安装可通过 `CTX_CLI_GEM=/absolute/path/ctx_cli-0.1.0.gem` 传入精确候选。


## Inventory and credentials without device operations

```ruby
require "net/connector/netdisco/catalog"
require "net/connector/credentials"

settings = Net::Connector::Netdisco::Settings.new(env: ENV)
policy = settings.snapshot(mode: :inventory)
catalog = Net::Connector::Netdisco::Catalog.new(settings: settings)
devices = catalog.devices(policy: policy)
# Inspect device.issue before selecting targets; duplicate rows are retained.
credentials = Net::Connector::Credentials.new(env: ENV).resolve(platform: :cisco_nxos)
```

Catalog owns inventory reading, normalization, duplicate marking and cache status (`#status`). It does not resolve device credentials, log into devices or create operation reports. Pass one policy snapshot throughout a run. Fleet delegates to Catalog and retains operation orchestration.

Credentials reads the injected environment on every `resolve`; it returns an independent frozen hash, or nil when no username is available. Platform-specific `NC_<PLATFORM>_USERNAME`, `_PASSWORD`, and `_ENABLE_PASSWORD` override `NC_DEVICE_USERNAME`, `NC_DEVICE_PASSWORD`, and `NC_ENABLE_PASSWORD` respectively. Blank values fall back. Secrets are never cached or included in object inspection.
