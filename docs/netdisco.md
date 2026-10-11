# Netdisco and fleet backups

[简体中文](netdisco.zh-CN.md) | [Home](../README.md) | [Device operations](usage.md)

## Configure inventory and credentials

Load `require "net/connector/netdisco"` for inventory and batch APIs. Netdisco supplies metadata; device credentials come from the environment or a caller-provided resolver. The full inventory is validated before device tasks start. Invalid addresses, unsupported vendors, filters, duplicates, missing credentials, failures, and partial results remain distinguishable.

For HTTP inventory:

```sh
export ND_URL=https://netdisco.example/netdisco
export ND_USERNAME=inventory-reader
export ND_PASSWORD='replace-me'
export NC_DEVICE_USERNAME=backup-user
export NC_DEVICE_PASSWORD='replace-me'
```

Use `ND_API_KEY` instead of the HTTP username/password pair when available. HTTPS retains standard certificate verification. HTTP is allowed by default for compatibility; set `netdisco.allow_insecure_http: false` to reject it before sending credentials.

YAML contains only non-sensitive settings. Unknown fields, Ruby object tags, and credentials in YAML are rejected. Settings precedence is CLI, supported environment variables, YAML, then defaults. Files load only through `--config FILE` or `NC_CONFIG`. Start with [backup.yml](../examples/backup.yml):

```yaml
netdisco:
  url: https://netdisco.example/netdisco
  allow_insecure_http: false
backup:
  directory: /var/backups/network
  concurrency: 4
inventory:
  include_vendors: [h3c, huawei, cisco_ios]
ssh:
  host_key_policy: strict
  max_script_output_bytes: null
tftp:
  server: 192.0.2.30
  vrfs:
    cisco_nxos: management
```

## CLI planning and execution

```sh
net-backup --config config.yml --show-config
net-backup --config config.yml --plan
net-backup --config config.yml --host 192.0.2.7 --success-policy selected
net-backup --config config.yml --tftp --plan
net-backup --config config.yml --tftp --all
net-backup --config config.yml --export 192.0.2.7 --output ./exports/device.cfg
```

The installed command is `net-backup`; source checkouts use `bundle exec bin/net-backup`. `--show-config` validates public settings without querying inventory. `--plan` queries and validates inventory without connecting devices. `--host` selects one address and fails if absent. Local CLI backups select all ready devices by default; TFTP selects at most five per vendor unless `--all` is given. `--limit-per-vendor` accepts 1 through 5.

`--export IP` reads an existing canonical `<IP>.txt` file offline. It writes original bytes to stdout, or atomically writes a private file with `--output`. It does not require inventory or device credentials. Hostname-prefixed batch-example files are not searched by this command.

Plans and results are JSON. Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | The requested success policy passed |
| `1` | Empty or incomplete batch under that policy |
| `2` | Configuration, inventory, or other CLI error |

The default `strict` policy requires a nonempty inventory, every outcome successful, and no callback/report errors. Filtered records still prevent strict success, so use `selected` when intentionally selecting one host or sampling. `selected` requires at least one success; remaining outcomes may only be `filtered` or `sample_limit`. Missing credentials, duplicates, invalid addresses, unsupported vendors, collisions, partial results, callback errors, and report errors all prevent it from passing.

`verified` adds server-file verification to selected success and requires TFTP with a local server directory. Strict `status` remains separate from `policy_success`; `coverage.complete` means every record was attempted, including failed tasks.

## Fleet API and reports

```ruby
require "net/connector/netdisco"

fleet = Net::Connector::Netdisco::Fleet.new
plan = fleet.plan_backup
puts plan.selected.map(&:host)
report = fleet.backup_all(plan: plan, success_policy: :selected, on_change: ->(outcome) {
  puts "#{outcome.device.host}: #{outcome.backup.change}"
})
puts report.counts
puts report.report_location
exit 1 unless report.policy_success?
```

`plan_backup` and `plan_tftp_backup` build inventory snapshots. Passing `plan:` preserves the selection and avoids another inventory query; malformed external plans are rejected before credentials, directories, or device I/O. Tasks run with bounded concurrency and retain inventory order. Ordinary device/callback failures do not discard other results; interruption stops workers and cleans resources.

Fleet returns `Netdisco::Report`, delegating raw execution fields to `report.batch`. `success?` and `status` remain strict; `policy_success?` evaluates the chosen policy. `summary` uses schema 2, with public settings, coverage, per-device diagnostics, timestamps, monotonic durations, and verification. `statistics` omits device detail. `Batch#build_report` only wraps existing execution data.

Local backups compare SHA-256. `on_change:` fires for created or changed artifacts; `on_start:` and `on_result:` observe attempted tasks. Callback faults appear in `callback_errors`. Saved artifacts with later errors remain `saved_with_error`; confirmed uploads with later errors remain `reported_with_error`. Neither result permits automatic replay.

`ResultStore::Json` writes private JSON by default. Use `ResultStore::Database.new(repository: YourModel)` with a `create!(attributes)` repository, or `result_store: nil` to persist yourself. Custom stores receive `write(report, directory:)`. Report errors retain known committed locations and prevent success.

## PostgreSQL inventory

Set `netdisco.source: postgres` and provide your own SELECT query. Table names and business filters are not built into the library. See [inventory_sql.yml](../examples/inventory_sql.yml):

```yaml
netdisco:
  source: postgres
  db_port: 5432
  db_sslmode: verify-full
  db_sslrootcert: /etc/net-connector/database-ca.crt
  db_connect_timeout: 10
  query: |
    SELECT host(ip) AS ip, name, dns, vendor, os, model, os_ver, serial
    FROM device
    WHERE vendor = $1
    ORDER BY ip
  query_params: [H3C]
```

The query must return unique column names including `ip`. Optional retained fields are `name`, `dns`, `vendor`, `os`, `model`, `os_ver`, and `serial`; other fields are discarded. Use `host(ip)` for PostgreSQL `inet` fields to omit prefixes. Parameters bind in array order, without interpolation or environment expansion. Use explicit ordering for repeatable selection.

```sh
export ND_DB_HOST=database.example
export ND_DB_NAME=netdisco
export ND_DB_USER=inventory-reader
export ND_DB_PASS='replace-me'
net-backup --config examples/inventory_sql.yml --plan
```

Host, database, user, and password are required. Source, query, and parameters may be overridden by `--source`, `--query`, and `--query-params`. They are public configuration and may appear in `--show-config`; passwords belong only in connection variables. HTTP credentials and device credentials are not prerequisites for a database-only plan.

The lazy-loaded `pg` driver owns one connection per query, uses a read-only transaction and parameterized cursor, and reads rows in single-row mode. Multiple statements, writes, and locking queries fail. Still grant the account only necessary SELECT privileges. Failure or timeout closes the connection and discards the entire inventory; raw SQL, parameters, and responses are excluded from diagnostics.

## Inventory budgets and policy snapshots

Default budgets cover authentication, pagination, fallback queries, or database FETCH operations: 500 rows per page, 10,000 pages, 100,000 records before deduplication, 16 MiB per response, 128 MiB total, and 300 seconds total. Configure them under `netdisco`. These are adjustable design defaults, not measured deployment capacity.

HTTP counts actual chunks and closes on excess. Injected `requester:` callbacks are checked only after returning; their blocking and memory belong to the caller. PostgreSQL counts column names and values, including discarded fields, after libpq decodes each row; a huge field may still consume driver memory before the check. Connection, query, and FETCH share the deadline and use database statement timeouts.

`Settings#snapshot(mode:)` freezes public policy before side effects. CLI planning and execution share it; later calls can read new settings. Credentials remain dynamic per task. `Settings.new.for_run(mode: :backup)` shares policy across API calls; non-sensitive overrides preserve an existing snapshot. A custom `credentials:` resolver can supply per-device connection options, taking precedence over defaults. Injected clients remain caller-owned.

Explicit host mappings, device rules, and vendor overrides take precedence over automatic detection. Comware plus a branded H3C model can correct stale vendor labels; H3C WX/AC models select the wireless connector.

## TFTP history and verification

Direct upload receipts only establish `device_reported`. Fleet can verify a local/mounted TFTP directory via `verification_root:`; the CLI accepts `--tftp-root DIR` or YAML `tftp.verification_root`. A verified receipt requires a current, nonempty regular file matching the actual receipt path, with SHA-256 evidence. Missing evidence prevents `verified` success.

Batch examples enable history preservation. With an accessible server directory, uploads use hostname/IP names and are retained in both `<batch>/tftp/` and server `archive/<batch>/`; pre-existing same-name files are archived under `previous/` before upload. File-state and filesystem-time baselines are captured under the upload lock. Verification or archival failure preserves available receipts and committed paths without reporting success.

Without a server directory, batch examples add a batch identifier to names, retain `device_reported`, and cannot save local configuration copies. PAN-OS uses the fixed `running-config.xml` name, so the history-preserving example refuses its upload without local server access. Plans still prevent same-batch filename collisions.

Reports distinguish `verification`, `server_file_verified`, `local_file`, `server_archive_file`, `bytes`, and `sha256`. TFTP has no configuration `change` notification.

## Batch examples and deployment

```sh
bundle exec ruby examples/backup.rb --json
bundle exec ruby examples/backup.rb --sample 3 --concurrency 10
bundle exec ruby examples/backup_tftp.rb --tftp-root /srv/tftp --success-policy verified
```

Examples default to all filtered devices and `selected` success, unlike the CLI's strict default and TFTP sampling. Sampling comes from `--sample` or YAML `backup.limit_per_vendor`. Examples create unique UTC+8 batch directories named `YYYY-MM-DD_HH-mm-ss`, adding a sequence on collision. Local files use hostname/IP names; generic Fleet/CLI backups default to IP names, replacing IPv6 colons with underscores. `filename_style: :hostname_ip` changes the path and comparison baseline when a device is renamed.

Each batch retains `plan.json`, `events.jsonl`, `summary.json`, and `summary.txt`, with private permissions. Human progress goes to stderr; `--json` controls JSON stdout. `--verbose` shows device events; `--no-progress` disables progress. TTY progress has a heartbeat and throughput/ETA, while redirected output reports every 25 devices. Terminal faults are retained as callback diagnostics without skipping tasks or reports.

Examples support hidden `--ask-password` and `--ask-netdisco-password` prompts, plus environment credentials. `--stdin-credentials` reads one JSON line with `netdisco_username`, `netdisco_password`, `device_username`, and `device_password`; a second `RUN` line confirms device execution. For PostgreSQL, the first pair overrides database user/password.

Examples load the project `.env` through `dotenv` without overriding existing environment values. Direct `ruby examples/backup.rb` uses the installed gem; `bundle exec ruby` tests checkout code. Example directory paths are based on the project root; an environment-provided `NC_CONFIG` resolves from the startup directory. Shared library helpers do not load `.env` or change directories. See [examples](../examples/README.md) (Chinese).

## Environment reference

| Variables | Purpose / default |
| --- | --- |
| `ND_URL` | HTTP inventory base URL |
| `ND_USERNAME`, `ND_PASSWORD` | HTTP login without API key |
| `ND_API_KEY` | Existing API key |
| `ND_DB_HOST`, `ND_DB_NAME`, `ND_DB_USER`, `ND_DB_PASS` | Required database connection fields |
| `NC_CONFIG` | Non-sensitive YAML file |
| `NC_DEVICE_USERNAME`, `NC_DEVICE_PASSWORD` | Default device credentials |
| `NC_<VENDOR>_USERNAME`, `NC_<VENDOR>_PASSWORD` | Vendor credentials, e.g. `CISCO_IOS` |
| `NC_ENABLE_PASSWORD`, `NC_<VENDOR>_ENABLE_PASSWORD` | Optional privilege credentials |

Only the variables listed above are supported. There are no legacy aliases. Public settings belong in YAML: budgets under `netdisco`, filters and mappings under `inventory`, script output budget and vendor protocols under `ssh`, and source files/VRFs under `tftp`. Database port, TLS mode, CA path, and connection timeout use `netdisco.db_port`, `db_sslmode`, `db_sslrootcert`, and `db_connect_timeout`. TFTP uses `tftp.server` and `tftp.verification_root`; progress uses `--no-progress`. Removed settings and old prefixes are rejected without echoing their values. Vendor source fields are `h3c_source_file`, `h3c_wireless_source_file`, and `huawei_source_file` under `tftp`.

Scheduling and durable queues belong to the caller. No device command retries are added by batch orchestration. For development gates and evidence limits, see [verification](VERIFICATION.md); for protected extension interfaces and report helpers, see [architecture](architecture.md) (Chinese).
