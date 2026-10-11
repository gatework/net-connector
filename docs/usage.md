# Device guide

[简体中文](usage.zh-CN.md) | [Home](../README.md) | [Netdisco and fleet backups](netdisco.md)

## Supported devices

Use these vendor keys with `Net::Connector.open` or `Net::Connector.build`:

| Vendor key | Devices | Configuration command | Save command |
| --- | --- | --- | --- |
| `:h3c` | H3C Comware | `dis cur` | `save force` |
| `:h3c_wireless` | H3C wireless controllers | `dis cur` | `save force` |
| `:cisco_ios` | Cisco IOS / IOS XE | `show running-config` | `copy running-config startup-config` |
| `:cisco_nxos` | Cisco NX-OS | `show running-config` | `copy run start` |
| `:huawei` | Huawei | `dis cur` | `save force` |
| `:hillstone` | Hillstone StoneOS | `show configuration running` | `save all` |
| `:radware` | Radware Alteon | `/cfg/dump` | `/cfg/save` |
| `:palo_alto` | Palo Alto PAN-OS | Set-format export from configuration view | Unsupported |

`device.supports?(:tftp_backup)` checks implemented capabilities without connecting. It does not establish firmware compatibility or account permissions. See the [capability matrix](architecture.md#厂商能力) (Chinese).

## Sessions and local backups

```ruby
require "net/connector"

Net::Connector.open(:cisco_ios,
  host: "192.0.2.10", username: ENV.fetch("NC_DEVICE_USERNAME"),
  password: ENV.fetch("NC_DEVICE_PASSWORD"),
  known_hosts: "/etc/net-connector/known_hosts", host_key_policy: :strict) do |device|
  backup = device.backup(path: "/var/backups/network/router.cfg", lock_timeout: 2)
  puts "#{backup.change}: #{backup.sha256}"
end
```

Create and protect the parent directory first. `open` closes the session on return, exception, or interruption. One connector owns one session; competing operations fail with `SessionBusy`.

`backup` locks the path before collecting, compares SHA-256, and reports `:created`, `:changed`, or `:unchanged`. Unchanged safe files retain their mtime. Default lock acquisition is immediate; contention raises `BackupBusy`. `lock_timeout:` allows a bounded wait. Call backup outside an existing session operation so path ownership precedes session ownership.

Writes use mode `0600`, file synchronization, atomic replacement, and parent-directory synchronization. A collection failure leaves the old file intact. Failure after replacement raises `BackupPersistenceError`; `error.backup` retains metadata and `error.receipt` distinguishes `:committed` from `:durable`. Unsupported directory synchronization is reported as `:backup_durability_unsupported`. Do not repeat the device operation to recover file finalization.

Private `.net-connector-<digest>.lock` files remain in the directory. All writers must follow the same locking protocol; ancestor directories remain the caller's responsibility.

For an in-memory configuration, use `device.running_config.value!`. The `Result` retains completed steps on failure. Collection suppresses configuration content in logs and error diagnostics, including debug/raw and application loggers; returned output and backup files remain sensitive.

## Device-initiated TFTP

```ruby
receipt = device.tftp_backup(host: "192.0.2.30", source_file: "flash:/startup.cfg",
                             path: "site/switch.cfg") # Huawei or H3C
```

H3C discovers its saved source with `display startup` when omitted; Huawei requires `source_file:`. IOS uses interactive `copy running-config tftp:`. NX-OS defaults to VRF `management`; Hillstone defaults to `mgt-vr`. These two vendors accept `vrf:`. Radware exports `.tgz`, Hillstone exports startup `.dat`, and PAN-OS always uploads `running-config.xml`.

The immutable `TftpReceipt` records `server`, actual `path`, `completed_at`, `configuration_kind`, `source_file`, `format`, `requested_path`, and verification fields. Direct calls return `:device_reported` with no server digest: they confirm device output, not the server file. Explicit source files are not assumed to contain running configuration. TFTP carries configuration without encryption; restrict its network access appropriately.

Explicit failure raises `:transfer_failed`; missing completion evidence raises `:transfer_unconfirmed`. A failure after confirmed upload raises `TftpCompletionError` with `error.receipt`. A mismatched explicit path is `:transfer_path_mismatch`; an unconfirmed actual path is `:transfer_path_unconfirmed` with receipt path `nil`. No automatic retransmission occurs. See the [single-device example](../examples/device_tftp.rb) and [server verification](netdisco.md#tftp-history-and-verification).

## TextFSM parsing

```ruby
interfaces = device.parse_command("show ip interface brief") # Cisco IOS
rows = device.parse_config(template: "cisco_ios_running_config_interfaces.textfsm")

saved = Net::Connector::Storage::SavedConfig.new(directory: "/var/backups/network")
rows = saved.parse(host: "192.0.2.10", template: "/path/to/template.textfsm")
```

Parsers return arrays of hashes with template field names. `parse_command` uses vendor/command lookup; `parse_config` requires a template. Pass `template:` or `template_dir:` to select external templates. No matches return `[]`; missing or invalid templates raise `ParsingError`, and device failures retain their connector error.

Parsing validates UTF-8 before and after terminal rendering. Invalid bytes raise `:invalid_output_encoding`; no encoding is guessed. Raw results, backups, and exports retain their bytes. Each parse has its own parser, and TextFSM loads only when parsing is requested.

## Topology and interface descriptions

```ruby
neighbors = device.neighbors
plan = device.plan_interface_descriptions
puts plan.commands.join("\n")
# Review the plan and approve the exact commands before applying it.
device.apply_interface_descriptions(plan, confirmed: true).value!
```

IOS/NX-OS use CDP; H3C, H3C wireless, Hillstone, and PAN-OS use LLDP. Neighbor records contain local interface, peer name/interface, chassis ID, and protocol. Unknown or partial output raises an error rather than becoming an empty table. Radware can read port names but cannot discover neighbors or apply descriptions.

The default description is `To <peer name> <peer interface abbreviation>`. Abbreviations preserve case. Use `abbreviate: false`, `lowercase: true`, or a formatter block to customize them. Raw identities and evidence are unchanged.

Apply requires `confirmed: true` and rechecks neighbor and description evidence. Changed evidence raises `:stale_plan` before writing. Supported immediate-change devices follow change, exit configuration, read back, then save. Failed/incomplete readback prevents save; unconfirmed persistence returns `:persistence_unconfirmed` with completed steps. Changes may already be active, so commands are never replayed or rolled back automatically.

PAN-OS supports read-only discovery and descriptions. Automatic changes are disabled with `:candidate_isolation_unavailable`; collection checks candidate differences before and after export and requires set format. See [topology contracts](architecture.md#业务约束) (Chinese) before extending these flows.

## Scripts and interactions

```ruby
script = Net::Connector::Script.parse(<<~CLI, name: "change-123")
  configure terminal
  interface GigabitEthernet1/0/1
  description uplink
  end
CLI
result = device.execute_script(script)
warn "#{result.error.code}: #{result.steps.size} completed commands" if result.failure?
```

`execute_command` runs one command; `execute_script` accepts a `Script` or command array. `Script.load(path)` reads a file. Commands are validated before I/O; completed steps survive later failures. `save_config` explicitly sends save commands; ordinary scripts do not save automatically.

Set `max_script_output_bytes:` to bound cumulative raw responses, including additional queries. Default is `nil`. Exceeding it returns `ScriptOutputLimitExceeded` (`:script_output_limit_exceeded`) and stops subsequent commands; the current command may already have executed. `max_output_bytes` separately limits each response. Neither setting is a process-memory limit.

Per-command prompts use `interactions: [Net::Connector::Interaction.new(/Token:\z/, ->(_) { "value\n" }, sensitive: true)]`. Mark commands containing secrets `sensitive: true`. For safe command text with sensitive output, use `output_sensitive: true`; `running_config` enables this automatically.

## Connections, host keys, and logging

`Configuration` accepts `protocol: :ssh` or `:telnet`, ports, timeouts, output limits, `known_hosts`, `log_file`, `logger`, `log_format`, and `log_level`. Host-key policy defaults to `:strict`. `:accept_new` registers first-use keys and rejects changed keys; `:replace` requires an explicit dedicated `known_hosts` file and replaces only the affected host on a recognized key-change failure. Never delete the persistent trust file to resolve an error.

`telnet_fallback` and `legacy_ssh` are disabled by default and apply only to recognized connection failures. Network login does not hold the shared trust-file lock. Authenticated merging has a separate `login_timeout` wait budget; `:known_hosts_busy` closes the session and preserves the shared file.

`log_file` requires a regular file, rejecting symlinks and special files. Text logs use Ruby Logger; `:info` records lifecycle events, `:debug` adds permitted output, and `:raw` writes protected device bytes. Injected `logger: Rails.logger` or a standard Logger keeps its ownership, formatting, and current threshold; the stricter of its level and `log_level` applies.

`on_event: ->(event) { ... }` receives frozen, redacted `Log::Event` values synchronously. Keep callbacks short; failures are surfaced as logging failures. Events include session/command IDs, operation, phase, duration, byte counts, and controlled diagnostics. `response_received` confirms a response, not device persistence or TFTP server verification. Custom events use `device.log_event("audit", level: :info, count: 2)`; sensitive scopes hide arbitrary custom payloads.

## Dependencies and extensions

Load device APIs with `require "net/connector"`; Netdisco has a separate entrypoint. Vendor implementations and TextFSM load on demand. Runtime dependencies declare minimum versions; the host application's lockfile selects compatible versions. Published TextFSM 0.2.0 constrains JSON to 2.x. The explicit JSON 3 source-patch matrix does not establish compatibility of the published dependency.

Examples use the development dependency `dotenv` to read the project `.env`; the library and CLI do not. Follow the [loading and migration reference](architecture.md#加载入口与厂商策略) (Chinese) for custom profiles, strategies, and protected hooks.
