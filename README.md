# net-connector

`net-connector` runs network device CLI sessions over SSH or Telnet. It collects running configuration, writes private backup files, executes command scripts, answers device prompts, records redacted session logs, and returns structured errors and partial results.

The code is organized by responsibility: `lib/net/connector/engine/` owns sessions, transport, scripts, results, and logging; `device/` owns the device facade, profile, running configuration and interface text helpers; `vendor/<name>.rb` assembles that vendor's rules from `vendor/<name>/running_config.rb`, `tftp_backup.rb` and `topology.rb` where needed; `operations/` owns shared backup, parsing and topology workflows; `netdisco/` owns inventory and batch orchestration. Identical vendor rules are shared. See [docs/architecture.md](docs/architecture.md) for the model. Load the public API with `require "net/connector"` or the Netdisco integration with `require "net/connector/netdisco"`. The public API loads vendor rules and parsing on demand; `require "net/connector/engine/core"` loads only the session execution layer.

Ruby 3.2+ and a POSIX system are required. SSH uses the local OpenSSH client. Telnet requires the local `telnet` program and must be selected explicitly. The gem depends on [`expect-pty`](https://rubygems.org/gems/expect-pty) 0.3.x (at least 0.3.1) and [`textfsm`](https://rubygems.org/gems/textfsm) 0.2.x.

## Install

```sh
gem install net-connector
```

```ruby
require "net/connector"
```

## Supported devices

Use `device.supports?(:tftp_backup)` or another capability to check whether a
connector implements an operation without contacting the device. The complete
[capability matrix and extension example](docs/architecture.md#vendor-capabilities)
cover collection, saving, TFTP, neighbor discovery, and description changes.
This check does not test device permissions or firmware behavior.

| Vendor key | Device family | Running configuration | Save configuration |
| --- | --- | --- | --- |
| `:h3c` | H3C Comware | `dis cur` | `save force` |
| `:h3c_wireless` | H3C wireless controller, Comware CLI | `dis cur` | `save force` |
| `:cisco_ios` | Cisco IOS / IOS XE | `show running-config` | `copy running-config startup-config` |
| `:cisco_nxos` | Cisco NX-OS | `show running-config` | `copy run start` |
| `:radware` | Radware Alteon CLI | `/cfg/dump` | `/cfg/save` |
| `:palo_alto` | Palo Alto PAN-OS CLI | set format candidate export | unsupported |
| `:huawei` | Huawei CLI | `dis cur` | `save force` |
| `:hillstone` | Hillstone StoneOS | `show configuration running` | `save all` |

Aliases `:cisco_n9k` and `:paloalto` are accepted. Vendor classes live directly under `Net::Connector`, such as `Net::Connector::H3cWireless::Connector`.

## Login and backup

```ruby
Net::Connector.open(:cisco_ios,
  host: "192.0.2.10", username: "admin", password: ENV.fetch("DEVICE_PASSWORD"),
  known_hosts: "/etc/net-connector/known_hosts", host_key_policy: :strict,
  log_file: "/var/log/net-connector/router.log") do |device|
  backup = device.backup(path: "/var/backups/router-running.cfg")
  puts "#{backup.bytes} bytes, SHA-256 #{backup.sha256}"
end
```

`open` closes the session even when the block fails. `backup` collects first, then atomically replaces the requested file with mode `0600`. Collection failure leaves an existing file unchanged. It returns `Backup(path:, bytes:, sha256:, collected_at:)`. The caller must create the destination directory and protect backups because running configurations can contain device secrets.

## Native TFTP backup

`tftp_backup` asks the device to send its native configuration directly to a TFTP server. Each vendor supplies its own command and prompt handling. For example, Huawei and H3C use a device file as the source:

```ruby
Net::Connector.open(:huawei, host: "192.0.2.20", username: ENV.fetch("DEVICE_USERNAME"),
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  transfer = device.tftp_backup(host: "192.0.2.30", source_file: "flash:/startup.cfg")
  puts "Uploaded #{transfer.path} to #{transfer.server}"
end
```

This emits `tftp 192.0.2.30 put flash:/startup.cfg`; pass `path: "site/switch.cfg"` to choose a different remote filename. H3C discovers its saved startup file with `display startup` unless `source_file:` is given. Huawei requires `source_file:` because its saved file location varies by model. Cisco IOS exports `running-config` using its interactive `copy running-config tftp:` flow. Cisco Nexus 9000 exports `running-config` with `vrf management` by default; pass `vrf: "other-vrf"` to override it. Hillstone exports the saved startup configuration with `export configuration startup to tftp server <server> <filename>`; its separate running-configuration query uses `show configuration running`. Radware Alteon uses `/cfg/ptcfg <server> -tftp`, produces a `.tgz` file, declines private-key export, and answers `mansync` for the internal-index prompt. Palo Alto exports `running-config.xml` and requires its fixed remote filename. All other vendors default the remote filename to `<management IP>.cfg`. The method returns `TftpBackup(server:, path:, completed_at:)` only when the device output confirms a transfer. Explicit device-side transfer failures use `:transfer_failed`; a missing success confirmation uses `:transfer_unconfirmed`. It does not read back the file from the TFTP server. TFTP carries configuration data without encryption; use it only on an appropriate management network.

The runnable [examples/tftp_backup.rb](examples/tftp_backup.rb) reads `DEVICE_VENDOR`, `DEVICE_HOST`, `DEVICE_USERNAME`, `DEVICE_PASSWORD`, and `TFTP_HOST` from the environment. Set `TFTP_SOURCE_FILE` for H3C or Huawei, `TFTP_PATH` for a remote filename, or `TFTP_VRF` to override the NX-OS VRF or Hillstone vrouter.

For in-memory collection, call `device.running_config`. It returns a `Result`; `result.value!` yields the cleaned configuration or raises its typed error.

## TextFSM parsing

`parse_command` executes one CLI command, then selects a TextFSM template by vendor and command. The bundled index covers Cisco IOS `show ip interface brief` and the CDP/LLDP commands used by topology discovery:

```ruby
Net::Connector.open(:cisco_ios, host: "192.0.2.10", username: "admin",
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  interfaces = device.parse_command("show ip interface brief")
  puts interfaces.first.fetch("INTERFACE")
end
```

`parse_config` collects the cleaned running configuration and requires an explicit template. The bundled Cisco IOS template extracts interface names and descriptions; it is not a complete configuration model:

```ruby
interfaces = device.parse_config(template: "cisco_ios_running_config_interfaces.textfsm")
```

Both methods return an Array of Hash records using the template's field names. A valid template with no matching records returns `[]`. A missing or invalid template raises `Net::Connector::ParsingError`; a failed device command retains its original connector error. To use other vendors or commands, provide `template: "/path/to/template.textfsm"`, or `template_dir: "/path/to/templates"` with a TextFSM `index` containing `Template, Vendor, Command` columns. Each parse creates a fresh parser, so concurrent device tasks do not share parsing state. Existing local backups can be parsed without connecting to a device:

```ruby
saved = Net::Connector::Operations::SavedConfig.new(directory: "/var/backups")
rows = saved.parse(host: "192.0.2.10", template: "/path/to/template.textfsm")
```

## Neighbors and interface descriptions

`neighbors` queries CDP on Cisco IOS/NX-OS and LLDP on H3C, H3C wireless, Hillstone, and PAN-OS. It returns records with `local_interface`, `neighbor_name`, `neighbor_interface`, `chassis_id`, and `protocol`. H3C LLDP list output is selected by its column header, covering releases that put the system name first or last. Unknown output raises `ParsingError`; it is not treated as an empty neighbor list. `interface_descriptions` reads the current running configuration, including Alteon port names in a Radware configuration dump.

```ruby
Net::Connector.open(:h3c, host: "192.0.2.10", username: ENV.fetch("DEVICE_USERNAME"),
                    password: ENV.fetch("DEVICE_PASSWORD")) do |device|
  plan = device.plan_interface_descriptions
  plan.changes.each { |change| puts "#{change.interface}: #{change.old_description.inspect} -> #{change.new_description.inspect}" }
  puts plan.commands.join("\n")
  # Review the exact commands and obtain operator approval before applying.
  result = device.apply_interface_descriptions(plan, confirmed: true)
  result.value!
end
```

The default proposal is `To <neighbor name> <abbreviated neighbor port>`. Abbreviation is enabled and preserves case: `ethernet1/1` becomes `eth1/1`, `Ethernet1/1` becomes `Eth1/1`, and `GigabitEthernet1/0/1` becomes `Gi1/0/1`. Unknown interface forms remain unchanged. Raw neighbors and plan evidence retain their original values; local command interface names are not abbreviated. Use `plan_interface_descriptions(abbreviate: false)` for the previous default, or `lowercase: true` to lowercase the remote port. Pass a block to control the complete description using the original neighbor. The pure common formatter is also available as `Net::Connector::InterfaceDescription.format(neighbor, abbreviate: true, lowercase: false)`. Planning rejects ambiguous neighbors, missing peer identities, unsafe text, and unrecognized output. Applying requires `confirmed: true` and reads neighbors and old descriptions again; changed evidence raises `:stale_plan`. The plan includes the vendor's save command; PAN-OS uses `commit`. After the script, the operation reads the configuration back and reports `:description_unconfirmed` if the new text is absent. A failed script returns a `Result` with completed steps and its error. Radware Alteon can advertise LLDP on documented versions, but its documented CLI does not provide neighbor discovery; `neighbors` therefore raises `:neighbor_discovery_unsupported`. Its port names remain readable through `interface_descriptions`. Validate commands and output against the specific firmware before using an approved plan on a live device.

PAN-OS collection checks for pending candidate changes before and after export, and rejects XML or non-set output. This avoids reporting an ambiguous candidate configuration as a running configuration backup. Device-specific CLI and firmware differences still need validation against the target device.

## Scripts and automatic interaction

```ruby
script = Net::Connector::Script.parse(<<~CLI, name: "change-123")
  # Comments on their own line are ignored.
  configure terminal
  interface GigabitEthernet1/0/1
  description uplink
  end
CLI

result = device.execute_script(script) do |step|
  puts "#{step.command.text}: #{step.duration.round(2)}s"
end

if result.failure?
  warn "#{result.error.code} at #{result.error.phase}"
  warn "#{result.steps.size} commands completed before failure"
end
```

`execute` sends one command; `execute_script` accepts a `Script` or an array of commands. `Script.load(path)` reads a file. Scripts are validated before any device I/O. A result retains completed steps when a later command fails. The library does not replay commands after failure. `save_config` explicitly sends the vendor's save command when supported; script execution does not save automatically.

Vendor profiles cover pager prompts and common confirmation prompts. For a command-specific dialogue, pass `interactions: [Net::Connector::Interaction.new(/Token:\z/, ->(_) { "value\n" }, sensitive: true)]` to `execute`. Sensitive commands and responses pause session logging and are redacted in errors. Do not place secrets in ordinary command text unless `sensitive: true` is set.

## Connection settings

`Configuration` accepts `protocol: :ssh` (default) or `:telnet`, `port`, `login_timeout`, `command_timeout`, `write_timeout`, `max_output_bytes`, `log_file`, `logger`, `log_format: :text` or `:raw`, `log_level: :info` (default), and `known_hosts`. Text logs use `ActiveSupport::Logger` and `TaggedLogging`: each line has a local timestamp, severity, device tag, and readable Chinese action. At `:info`, one `log_file` contains connection, login, command, and TFTP outcomes. At `:debug`, that same file also contains sanitized login and device output plus command timing. No separate transcript file is created. `:warn` and `:error` retain only events at those levels or higher. The TFTP example defaults to `:debug`; set `NET_CONNECTOR_LOG_LEVEL` to change it. `log_format: :raw` writes only device bytes to `log_file` without event metadata. Configured credentials and sensitive command interactions are excluded from device output. Inject a Rails logger with `logger: Rails.logger` to send tagged events to the host application; the connector does not close or change its level. Host key policy defaults to `:strict`; `:accept_new` allows first-contact keys, while `:replace` requires an explicit known-hosts file. `telnet_fallback` and `legacy_ssh` are disabled by default and only apply to known connection failures. Commands are passed as argv, without a shell.

Telnet sends credentials without SSH encryption. Enable it only on a trusted management network. The gem does not check device authorization or review change plans; callers must enforce their own operational approval flow.

## Netdisco inventory and batch backup

`Net::Connector::Netdisco` reads the full Netdisco device inventory, maps supported rows to connector instances, then runs backups with a bounded number of worker threads. Netdisco supplies only inventory fields; device login credentials come from your environment or a resolver you provide. Inventory is fetched and validated before any device session starts. Unsupported, filtered, duplicate, missing-credential, failed, and saved-with-close-error outcomes stay distinct.

`Fleet#plan_backup` and `Fleet#plan_tftp_backup` select devices from one validated Netdisco snapshot. Pass the returned plan to `backup_all(plan:)` or `tftp_backup_all(plan:)` so the preview and execution use exactly the same devices. Execution rejects a plan whose tasks or skip results no longer match its inventory. `Netdisco::Worker` runs each selected device independently; an exception or result-callback failure on one device does not stop the others. `batch.summary` reports total, succeeded, failed, partial, skipped, exact status counts, per-device outcomes, and an overall `status` of `succeeded`, `incomplete`, or `no_devices`. A partial result means the device reported a completed backup but closing its session failed. TFTP `reported_uploaded` only means the device reported an upload; it does not verify a file on the server.

Local `backup(path:)` compares the new configuration with the existing file by SHA-256. It reports `:created`, `:changed`, or `:unchanged` through `backup.change`; unchanged files keep their modification time. The `on_change:` callback on `backup_all` runs only after a newly created or changed file is saved, including a saved file whose session later fails to close. `on_start:` and `on_result:` observe each attempted device for either batch method. Callback exceptions are recorded in `batch.callback_errors` without stopping other devices. Each outcome records its start, finish, and duration. TFTP uploads have no `change` value because this library cannot compare the server file; a device-reported upload must not trigger a change notification.

Each batch writes a private JSON report by default and returns its path in `batch.report_location`. Set `result_store: Net::Connector::Netdisco::ResultStore::Database.new(repository: YourModel)` when the caller owns a database table; the repository must implement `create!(attributes)` for `batch.summary`. Pass `result_store: nil` to handle persistence elsewhere. Report write failures remain visible as `batch.report_error`, and `batch.success?` becomes false without losing device outcomes.

```sh
export NETDISCO_URL=https://netdisco.example/netdisco
export NETDISCO_USERNAME=inventory-reader
export NETDISCO_PASSWORD='replace-me'
export NET_CONNECTOR_DEVICE_USERNAME=backup-user
export NET_CONNECTOR_DEVICE_PASSWORD='replace-me'
export NET_CONNECTOR_BACKUP_DIRECTORY=/var/backups/network
export NET_CONNECTOR_CONCURRENCY=4
```

```ruby
require "net/connector/netdisco"

fleet = Net::Connector::Netdisco::Fleet.new
plan = fleet.plan_backup
puts plan.selected.map(&:host)
batch = fleet.backup_all(plan: plan, on_change: ->(outcome) {
  puts "#{outcome.device.host}: #{outcome.backup.change}"
})
puts batch.counts
puts batch.summary.slice(:succeeded, :failed, :partial, :skipped)
puts batch.report_location
batch.outcomes.each do |outcome|
  puts "#{outcome.device.source_ip}: #{outcome.status} #{outcome.backup&.path}"
end
exit 1 unless batch.success?
```

The gem also installs `net-connector-backup`. Its YAML file contains non-secret settings; keep Netdisco and device credentials in environment variables. Environment variables override YAML values. The file is loaded only when `--config FILE` or `NET_CONNECTOR_CONFIG` is set. For example:

```yaml
netdisco:
  url: https://netdisco.example/netdisco
  page_size: 500
backup:
  directory: /var/backups/network
  concurrency: 4
inventory:
  include_vendors: [h3c, huawei, cisco_ios]
  host_overrides:
    192.0.2.7: h3c_wireless
ssh:
  host_key_policy: strict
tftp:
  server: 192.0.2.10
  vrfs:
    cisco_nxos: management
```

```sh
net-connector-backup --config config.yml --show-config
net-connector-backup --config config.yml --plan --host 192.0.2.7
net-connector-backup --config config.yml --host 192.0.2.7
net-connector-backup --config config.yml --tftp --plan
net-connector-backup --config config.yml --tftp --all
net-connector-backup --config config.yml --export 192.0.2.7 --output ./exports/device.cfg
```

`--plan` fetches and validates inventory without logging into devices. `--host` selects one management IP from that inventory. `--tftp` selects up to five devices per vendor by default; `--all` selects every ready device. Local backups select all ready devices unless `--limit-per-vendor` or `backup.limit_per_vendor` is set. `--show-config` prints effective non-secret settings and does not contact Netdisco. The CLI rejects unknown YAML keys, Ruby object tags, and secrets in the YAML schema. `--export IP` reads an existing local `<IP>.txt` backup (or a unique legacy `<device name>-<IP>.txt` file) without contacting Netdisco or the device; it writes the exact contents to stdout, or atomically creates a mode `0600` file when `--output` is set. Treat exported configurations as sensitive.

The CLI prints JSON for plans and batch summaries. Exit status is `0` when a nonempty inventory has only successful outcomes, `1` when the inventory is empty or any outcome was skipped, partial, or failed, and `2` for an inventory or configuration error. A `--host` address absent from the inventory is an error with status `2`. A `--host` run can return `1` when its selected backup succeeds because other inventory rows are reported as filtered; inspect `succeeded`, `skipped`, and per-device `status` in the JSON summary.

For a small live trial, run [examples/netdisco_backup.rb](examples/netdisco_backup.rb). It fetches a validated inventory snapshot and backs up at most three ready devices per mapped vendor by default. Set `NET_CONNECTOR_SAMPLE_PER_VENDOR` to an integer from 1 to 5 to change the sample size. Results and a per-device `summary.json` are written under a unique `examples/backups/<UTC timestamp>-<suffix>/` directory; that directory is Git-ignored. The example uses the same environment variables listed below.

For device-initiated TFTP uploads, run [examples/netdisco_tftp_backup.rb](examples/netdisco_tftp_backup.rb) with `NETDISCO_URL`, `TFTP_HOST`, and the credential environment variables below. It samples at most five devices per vendor by default; set `NET_CONNECTOR_ALL=1` to select every ready inventory device. Full runs use 50 simultaneous tasks by default; `NET_CONNECTOR_CONCURRENCY` can override this. The full-run plan is saved as `plan.json`. Remote filenames are unique `<device name>-<IP>.cfg` (`.tgz` for Radware, `.dat` for Hillstone). PAN-OS uses its fixed `running-config.xml` filename: additional Palo Alto devices are reported as `remote_filename_collision` rather than overwriting another backup. PAN-OS requires a positive `Sent ... bytes` response to report upload success. H3C and H3C wireless read `display startup` to find the saved startup file; override the source with `NET_CONNECTOR_H3C_TFTP_SOURCE_FILE` or `NET_CONNECTOR_H3C_WIRELESS_TFTP_SOURCE_FILE`. Huawei defaults to `flash:/startup.cfg` and accepts `NET_CONNECTOR_HUAWEI_TFTP_SOURCE_FILE`. Nexus 9000 uses `management` by default and Hillstone uses `mgt-vr`; set `NET_CONNECTOR_TFTP_VRFS` to a JSON map such as `{"cisco_nxos":"backup","hillstone":"mgt-vr"}` to override either one. Hillstone appends its unique `.dat` filename after the device `vrouter` argument. When calling a Hillstone connector directly without `path:`, the device generates its own filename and the return value reports that filename. `reported_uploaded` means the device reported success. Small runs attempt a server readback; full runs skip per-file readback and mark these files unverified. Run `ruby examples/review_tftp_backup.rb <batch directory>` to keep the original summary and review remaining failures from the session logs. Each `logs/<IP>.log` contains the session events and a final backup result; at debug level it also includes the sanitized login and device output in that same file. Per-device outcomes, incremental `events.jsonl`, and logs are written privately under a unique `examples/backups/<UTC timestamp>-<suffix>/` directory.

Local backups are written to `<backup directory>/<IP>.txt`, using the normalized management IP; `:` in IPv6 addresses becomes `_`. Device renames preserve the filename and comparison baseline. If the canonical file is absent, a unique legacy `<device name>-<IP>.txt` file supplies the comparison baseline and remains untouched. Multiple legacy matches fail explicitly; review them and place the verified current configuration at the canonical path. Canonical files take precedence, and symlinks or non-regular files are rejected. Inventory names remain in result metadata and TFTP filenames. Files are atomically replaced with mode `0600`. The directory is created with mode `0700` if absent. A batch runs in the current process; schedule it with your job runner or cron if you need recurring or durable work. It does not retry a failed device command.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `NETDISCO_URL` | required | Netdisco base URL, including any tenant path |
| `NET_CONNECTOR_CONFIG` | unset | Explicit non-secret YAML settings file for the CLI |
| `NETDISCO_USERNAME`, `NETDISCO_PASSWORD` | required unless API key is supplied | Inventory API login |
| `NETDISCO_API_KEY` | unset | Use an existing API key instead of login |
| `NETDISCO_PAGE_SIZE` | `500` | Device inventory page size |
| `NET_CONNECTOR_DEVICE_USERNAME`, `NET_CONNECTOR_DEVICE_PASSWORD` | unset | Device login defaults |
| `NET_CONNECTOR_<VENDOR>_USERNAME`, `NET_CONNECTOR_<VENDOR>_PASSWORD` | unset | Override credentials for one connector key, such as `CISCO_IOS` |
| `NET_CONNECTOR_BACKUP_DIRECTORY` | `./backups` | Backup destination and default batch-report directory |
| `NET_CONNECTOR_CONCURRENCY` | `4` | Maximum simultaneous device backups, from 1 to 50 |
| `NET_CONNECTOR_INCLUDE_HOSTS`, `NET_CONNECTOR_EXCLUDE_HOSTS` | unset | Comma-separated management IP filters |
| `NET_CONNECTOR_INCLUDE_VENDORS` | unset | Comma-separated connector keys to include |
| `NET_CONNECTOR_VENDOR_OVERRIDES` | `{}` | JSON object mapping a Netdisco vendor label to a connector key |
| `NET_CONNECTOR_HOST_OVERRIDES` | `{}` | JSON object mapping a management IP to a connector key |
| `NET_CONNECTOR_DEVICE_RULES` | `[]` | JSON array of mapping rules with `vendor`, optional `os` or `model_prefix`, and `connector` |
| `NET_CONNECTOR_PROTOCOL` | `ssh` | Default device protocol; per-vendor override is available |
| `NET_CONNECTOR_KNOWN_HOSTS`, `NET_CONNECTOR_HOST_KEY_POLICY` | system hosts, `strict` | SSH host-key settings |
| `NET_CONNECTOR_LOG_DIRECTORY` | unset | Optional per-device session log directory |
| `NET_CONNECTOR_LOG_LEVEL` | `info` (`debug` in TFTP example) | `debug`, `info`, `warn`, or `error` event detail |
| `NET_CONNECTOR_TFTP_VRFS` | `{}` | JSON map of NX-OS and Hillstone VRF names for the TFTP example |

Mapping rules are evaluated before vendor-label overrides and built-in rules. A specific rule can distinguish models that share a vendor label:

```sh
export NET_CONNECTOR_DEVICE_RULES='[{"vendor":"Cisco","model_prefix":"N9K","connector":"cisco_nxos"}]'
```

The environment is read when a `Settings` object builds its client or rules, and device credentials are read for each backup task. A new batch can therefore pick up rotated credentials. For per-device secrets managed outside the environment, inject a resolver: `Fleet.new(credentials: ->(device) { { username: "...", password: "..." } })`. To inspect association without connecting, call `fleet.devices`; a ready item can instantiate its connector with `device.connector(username: "...", password: "...")`.

## Development

```sh
bundle install
script/ci
```

The same command runs in CI on Linux and macOS with Ruby 3.2, 3.3, 3.4 and 4.0.
It scans source and available Git history for sensitive data, runs Ruby and
workflow lint plus the complete test suite, and verifies the built gem through
isolated installation and a real local PTY session. No network device is needed.
The first run downloads checksum-pinned Gitleaks and actionlint binaries.

`bundle exec rake test` runs tests, `bundle exec rake lint` checks Ruby code,
and `bundle exec rake security:check` scans source and history. The full
pre-release check is also available as `bundle exec rake release:check`.
Builds and redacted scan reports go under ignored `tmp/` directories.

Keep real credentials in environment variables and local configuration outside
version control. See [verification and sensitive-data policy](docs/VERIFICATION.md)
for scan coverage, dependency policy and `.gitignore`, and
[release instructions](docs/RELEASING.md) for local and GitHub Actions publishing.
