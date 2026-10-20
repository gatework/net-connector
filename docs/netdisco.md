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

`NC_PARALLEL` sets the default worker count for backups, configuration scripts and interface changes (1–500, default 4). An explicit API argument or CLI option takes precedence over the environment, then YAML.

Before connecting devices, batches reserve file descriptor capacity for SSH pipes, PTYs, logs and locks. The process soft limit is raised within its existing hard limit when needed; an insufficient hard limit stops execution with a `ulimit -n` hint. Shell and system limits are not changed. SSH archive connections are sized per server, with up to four simultaneous connection preflights.

YAML contains only non-sensitive settings. Unknown fields, Ruby object tags, and credentials in YAML are rejected. CLI precedence is CLI options, original process environment, layered YAML, layered `.env`, then defaults. The shared process `NC_PARALLEL` also overrides YAML `topology.parallel`; the mode-specific process `NC_TOPOLOGY_PARALLEL` wins within that layer, and CLI `--parallel` wins overall. Canonical public environment names follow `Config::FIELDS`; library `Settings.from_env` and `Settings.from_file` retain their explicit contracts. Start with [backup.example.yml](../examples/backup.example.yml):

```yaml
netdisco:
  url: https://netdisco.example/netdisco
  allow_insecure_http: false
backup:
  directory: /var/backups/network
  parallel: 4
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

## Inventory cache

HTTP and PostgreSQL inventory use a local cache by default, valid for three days (259,200 seconds). The default directory is `.cache/net-connector/inventory`, relative to the current working directory. Configure it through YAML:

```yaml
netdisco:
  cache_directory: /var/cache/network/inventory
  cache_ttl: 259200
  cache_enabled: true
```

`ND_CACHE_TTL=86400` sets a one-day lifetime. Explicit settings overrides take precedence over the environment, then YAML, then the three-day default. TTL must be finite and positive; each batch fixes its policy snapshot before scheduling.

The directory must belong to the current user with mode `0700`; cache and lock files use `0600`. Source, account, database and SQL parameters partition the cache. Only inventory fields are stored; passwords, API keys, SQL and extra response fields are excluded. Each read applies current filtering and vendor rules. A successful empty inventory replaces history.

Expired inventory refreshes automatically. A remote inventory failure falls back to validated history without changing its original timestamp. Configuration errors, missing credentials, interruption and unsafe files remain errors. Failed cache writes preserve newly fetched inventory. `fleet.inventory_status` reports `:fresh_cache`, `:refreshed`, `:stale_cache` or `:uncached`, the original `fetched_at`, and safe failure metadata; the CLI warns on history fallback or cache write failure.

An empty or malformed cache file is a cache miss and triggers a remote query. It cannot supply fallback history if that query fails.

Use `net-backup --refresh-inventory`, `fleet.devices(force_refresh: true)`, or `fleet.plan_backup(force_refresh: true)` to bypass freshness. TFTP planning accepts the same keyword. A forced refresh also falls back to valid history if the remote request fails. `cache_enabled: false` disables caching. Injected inventory sources stay uncached unless explicitly wrapped in `Netdisco::Inventory::Cache`; shared wrapper status describes the latest call, so synchronize concurrent access to the same instance. Cache locks bound waiting and coalesce ordinary expired-cache refreshes across processes; independently requested forced refreshes still query the source.

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

Here `vendor` is the connector platform key, such as `cisco_ios` or `cisco_nxos`, rather than the manufacturer. Filtering and sampling use that key: a limit of five can select five IOS devices and five NX-OS devices. `source_vendor` retains the original inventory vendor label.

Interactive batch examples use `CLI::Backup` and `CLI::Topology`; `CLI::Credentials.resolve` supplies the inventory source and per-device credential resolver, while `CLI::Options` parses arguments and configuration overrides. These components live under `netdisco/cli/`. All entrypoints use the same configuration snapshot: CLI > process environment > YAML > `.env` > built-in defaults. Initialization consumes that snapshot too; there is no separate environment-loading switch.

Host, name and vendor selectors reject whitespace-only entries and empty comma-separated items. YAML `[]` and an empty environment string explicitly clear a selector; malformed text never becomes an unrestricted selection. Higher-priority replacements are applied before the effective selector is validated.

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

`plan_backup` and `plan_tftp_backup` build inventory snapshots. Passing `plan:` preserves the selection and avoids another inventory query; malformed external plans are rejected before credentials, directories, or device I/O. Tasks run with bounded parallel and retain inventory order. Ordinary device/callback failures do not discard other results; interruption stops workers and cleans resources.

Fleet returns `Netdisco::Report`, delegating raw execution fields to `report.batch`. `success?` and `status` remain strict; `policy_success?` evaluates the chosen policy. `summary` uses schema 2, with public settings, coverage, per-device diagnostics, timestamps, monotonic durations, and verification. `statistics` omits device detail. `Batch#build_report` only wraps existing execution data.

Local backups compare SHA-256. `on_change:` fires for created or changed artifacts; `on_start:` and `on_result:` observe attempted tasks. Callback faults appear in `callback_errors`. Saved artifacts with later errors remain `saved_with_error`; confirmed uploads with later errors remain `reported_with_error`. Neither result permits automatic replay.

`Report::Store::Json` writes private JSON by default. Use `Report::Store::Database.new(repository: YourModel)` with a `create!(attributes)` repository, or `report_store: nil` to persist yourself. Custom stores receive `write(report, directory:)`. Report errors retain known committed locations and prevent success.

## Configuration batches and interface changes

```ruby
fleet = Net::Connector::Netdisco::Fleet.new
batch = fleet.execute_scripts(
  scripts: { "192.0.2.1" => ["system-view", "interface GigabitEthernet1/0/1", "description uplink", "quit", "quit"] },
  confirmed: true,
  parallel: 4
)
puts JSON.pretty_generate(batch.to_h)
puts "Total=#{batch.summary[:total]} succeeded=#{batch.summary[:succeeded]} failed=#{batch.summary[:failed]}"

batch = fleet.sync_descriptions(hosts: ["192.0.2.1"])
puts "Total=#{batch.summary[:total]} succeeded=#{batch.summary[:succeeded]} failed=#{batch.summary[:failed]}"
```

Scripts accept `Script`, command arrays or multiline text. The full batch is parsed and target addresses are normalized before credentials or device connections; duplicate, unknown, filtered and unsupported targets are rejected. Scripts contain the vendor's complete commands, including mode transitions and save commands where required. An empty batch reports `:no_devices` and is unsuccessful.

Interface application calls the existing topology operation, retaining evidence revalidation, configuration readback and persistence confirmation. It does not execute an approved plan as an ordinary script. Both write operations require `confirmed: true`, and never automatically retry commands. Each task owns and closes its connector. Ordinary failures remain per-device outcomes; `Interrupt` stops and joins all owned workers. Confirmed work is not rolled back across devices.

`Operation::Batch` is separate from backup reports. `outcomes` retain the original `Result` or plan, completed steps and the first failure; `:partial` preserves work followed by an error, and missing credentials prevent success. `plans` selects only fully successful planning results. `to_h` includes safe diagnostics and counts, excluding commands, outputs, credentials and evidence. `on_start` and `on_result` run on workers and must be thread safe; ordinary callback faults are recorded without repeating device operations. Logging uses the configured `ssh.log_directory`.

Device outcomes are published before `on_result`. After an `Interrupt`, inspect `Fleet#last_operation_batch` or `Operation#last_batch`: completed outcomes remain intact, started tasks without a result are `:interrupted`, and queued tasks are `:not_started`. The batch has `interrupted: true`, reports `:interrupted`, and cannot report success even if every device finished before a callback cancelled the batch. Cancelled tasks have no measured duration; unstarted tasks also have no timestamps. The original interrupt propagates after worker cleanup. An interrupted task may already have changed its device; read back its state before deciding what to do next. Each new operation attempt clears the previous operation batch, including attempts rejected during preflight. Backup reports remain available separately through `Fleet#last_report`.

These multi-device APIs return `Operation::Batch` and invoke each device through `device.interfaces.plan/apply/sync`. See the [device guide](usage.md#topology-and-interface-descriptions) for single-device reads, audit and changes.

`sync_descriptions` is the direct update entry: one request and one connection per device, from discovery through readback and save. Matching descriptions cause no writes or saves; a no-op does not confirm an earlier save. The default format is `To_<peer name>_<interface abbreviation>`; formatting options and blocks remain backend choices. Separate preview/approval workflows remain available through `plan_descriptions` and `apply_descriptions(plans: planned.plans, confirmed: true)`.

Each device publishes one immutable outcome after execution and connection cleanup. Ordinary credential, connection, execution and cleanup failures affect that device while active and queued siblings continue. Once scheduling completes, `summary` and `to_h[:summary]` report `total`, `succeeded` and `failed`, with total = succeeded + failed. Total counts the devices requested and scheduled in this batch; partial completion and missing credentials count as failures and also appear in `partial` and `missing_credentials`. `callback_errors` counts notification faults separately without changing device outcomes. Empty batches report zero counts and `no_devices`. The library returns the report; callers choose terminal output or JSON export. Whole-batch approval validation and interruption retain their existing boundaries, and completed device changes cannot be rolled back.

For other independent tasks, load `net/connector/parallel/pool` and use `Net::Connector::Parallel::Pool.new(parallel: 4).map(items) { |item| ... }`. Results preserve input order, all threads must start before any block runs, and uncaught exceptions stop the pool and propagate to its caller. Business code decides which ordinary errors become per-task results.

## PostgreSQL inventory

Set `netdisco.source: postgres` and provide your own SELECT query. Table names and business filters are not built into the library. See [inventory.yml](../examples/inventory.yml):

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
net-backup --config examples/inventory.yml --plan
```

Host, database, user, and password are required. Source, query, and parameters may be overridden by `--source`, `--query`, and `--query-params`. They are public configuration and may appear in `--show-config`; passwords belong only in connection variables. HTTP credentials and device credentials are not prerequisites for a database-only plan.

The lazy-loaded `pg` driver owns one connection per query, uses a read-only transaction and parameterized cursor, and reads rows in single-row mode. Multiple statements, writes, and locking queries fail. Still grant the account only necessary SELECT privileges. Failure or timeout closes the connection and discards the entire inventory; raw SQL, parameters, and responses are excluded from diagnostics.

## Inventory budgets and policy snapshots

Default budgets cover authentication, pagination, fallback queries, or database FETCH operations: 500 rows per page, 10,000 pages, 100,000 records before deduplication, 16 MiB per response, 128 MiB total, and 300 seconds total. Configure them under `netdisco`. These are adjustable design defaults, not measured deployment capacity.

HTTP counts actual chunks and closes on excess. Injected `requester:` callbacks are checked only after returning; their blocking and memory belong to the caller. PostgreSQL counts column names and values, including discarded fields, after libpq decodes each row; a huge field may still consume driver memory before the check. Connection, query, and FETCH share the deadline and use database statement timeouts.

`Settings#snapshot(mode:)` freezes public policy before side effects. CLI planning and execution share it; later calls can read new settings. Credentials remain dynamic per task. `Settings.new.for_run(mode: :backup)` shares policy across API calls; non-sensitive overrides preserve an existing snapshot. A custom `credentials:` resolver can supply per-device connection options, taking precedence over defaults. Injected inventory sources remain caller-owned.

Snapshot backup, cache, log, TFTP verification, SSH known-hosts and explicit PostgreSQL CA certificate paths resolve against the working directory captured when the snapshot is created, including default paths and later relative overrides. Paths beginning with `~/` and the path `~` use the home directory captured by that snapshot. PostgreSQL CA paths retain libpq's literal path semantics without tilde expansion; `sslrootcert: system` keeps its system trust-store meaning, while `./system` names a file. Live settings continue to resolve paths against the current working directory and home directory.

Explicit host mappings, device rules, and vendor overrides take precedence over automatic detection. Comware plus a branded H3C model can correct stale vendor labels; H3C WX/AC models select the wireless connector.

Host and vendor overrides reject normalized aliases that select different connectors; aliases selecting the same connector can coexist. Required vendor labels must remain nonempty after normalization. Invalid rules fail before device connections begin.

## TFTP history and verification

For an SSH-only server, use a password-free root such as `ssh://archive@backup.example/srv/tftp`
in `tftp.verification_roots`, keyed by the corresponding TFTP server. SSH roots require
`preserve_history: true` (enabled by the example CLI). The server needs Python 3 and a writable
archive root. Supply `NC_TFTP_SSH_PASSWORD` through the caller's credential environment,
or use an available SSH key/agent. The example scripts load this credential from the
project-root `.env`. Authentication never prompts: missing or rejected credentials
stop the batch before device connections and print an actionable error. Passwords
are sent through a private, unlogged PTY and never appear in policy or SSH arguments.
The remote lock spans upload and verification, existing files are preserved first, and staging
is removed only after both server and local archives have matching SHA-256 evidence.
The SSH archive pool allows four concurrent transactions and limits each file to 64 MiB.
See [example setup](../examples/README.md#ssh-服务器核验与归档).

Direct upload receipts only establish `device_reported`. Fleet can verify a local/mounted TFTP directory via `verification_root:`; the CLI accepts `--tftp-root DIR` or YAML `tftp.verification_root`. A verified receipt requires a current, nonempty regular file matching the actual receipt path, with SHA-256 evidence. Missing evidence prevents `verified` success. A mismatched receipt path is retained as device evidence, but cannot be verified or archived without a baseline for that locked target.

Verification holds a target lock across the pre-upload file-state/time baseline, upload and fingerprint check, including batches without history preservation. An unchanged old file cannot qualify through a future timestamp. The server directory must be writable for lock files and the filesystem-time probe. Result callbacks receive the verified outcome, and file evidence never substitutes for a failed device operation or cleanup.

Batch examples enable history preservation. With an accessible server directory, uploads use hostname/IP names and are retained in both `<batch>/tftp/` and server `archive/<batch>/`; pre-existing same-name files are archived under `previous/` before upload. File-state and filesystem-time baselines are captured under the upload lock. Verification or archival failure preserves available receipts and committed paths without reporting success.

Path-lock cleanup failures after a completed local backup or TFTP archive retain the saved paths as `:saved_with_error` or `:reported_with_error`. An earlier device error remains the primary diagnostic; callbacks receive the retained outcome and commands are not replayed.

Without a server directory, batch examples add a batch identifier to names, retain `device_reported`, and cannot save local configuration copies. PAN-OS uses the fixed `running-config.xml` name, so the history-preserving example refuses its upload without local server access. Plans still prevent same-batch filename collisions.

Reports distinguish `verification`, `server_file_verified`, `local_file`, `server_archive_file`, `bytes`, and `sha256`. TFTP has no configuration `change` notification.

## Batch examples and deployment

```sh
bundle exec ruby examples/backup.rb --json
bundle exec ruby examples/backup.rb --sample 3 --parallel 10
bundle exec ruby examples/backup_tftp.rb --tftp-root /srv/tftp --success-policy verified
```

Examples default to all filtered devices and `selected` success, unlike the CLI's strict default and TFTP sampling. Sampling comes from `--sample` or YAML `backup.limit_per_vendor`. Examples create unique UTC+8 batch directories named `YYYY-MM-DD_HH-mm-ss`, adding a sequence on collision. Local files use hostname/IP names; generic Fleet/CLI backups default to IP names, replacing IPv6 colons with underscores. `filename_style: :hostname_ip` changes the path and comparison baseline when a device is renamed.

Each batch retains `plan.json`, `events.jsonl`, `summary.json`, and `summary.txt`, with private permissions. Human progress goes to stderr; `--json` controls JSON stdout. `--verbose` shows device events; `--no-progress` disables progress. TTY progress has a heartbeat and throughput/ETA, while redirected output reports every 25 devices. Terminal faults are retained as callback diagnostics without skipping tasks or reports.

Examples support hidden `--ask-password` and `--ask-netdisco-password` prompts, plus environment credentials. `--stdin-credentials` reads one JSON line with `netdisco_username`, `netdisco_password`, `device_username`, and `device_password`; a second `RUN` line confirms device execution. For PostgreSQL, the first pair overrides database user/password.

CLI and example hosts discover directories from low to high: `/etc/net-connector`, `/usr/local/etc/net-connector`, `$XDG_CONFIG_HOME/net-connector` (default `~/.config/net-connector` for the running user), the entry script directory, and startup cwd. Duplicate directories are read once; parents are not searched. Each directory contributes `net-connector.yml` (`common` then `backup` or `topology` namespaces), then its tool YAML, plus `.env`. Common settings accept only `netdisco`, `inventory`, and `ssh`; tool namespaces contain a complete native tool document. `--config FILE` / `NC_CONFIG` append a final YAML layer; `--env-file FILE` appends a final environment layer. Arrays replace as a whole. YAML local paths resolve relative to their source file; `.env` selectors and declared paths resolve relative to that environment file; CLI and process paths resolve from startup cwd. SSH TFTP URIs remain intact. Explicit missing or malformed files fail; absent automatic candidates are skipped. Each YAML file must contain one document with unique mapping keys; duplicate keys and additional documents are rejected before settings are merged. `--show-config` reports public settings and source paths without passwords or environment file contents. Help reads no configuration. `--init` creates missing YAML and `.env` files in the user configuration directory or explicit paths, without overwriting existing files. It never writes into the installed gem directory. Default outputs remain `backups/` and `topologys/` under startup cwd. Hosts leave `ENV` and cwd unchanged. Both plain `ruby examples/backup.rb` and `bundle exec ruby examples/backup.rb` load the adjacent project library; third-party dependencies retain the caller's RubyGems/Bundler selection. The installed `net-backup` executable uses its installed gem. See [examples](../examples/README.md) (Chinese).

An explicitly selected `net-connector.yml` retains the same shared namespaces and source-relative paths as automatic discovery. `--init --non-interactive` writes a parallel count only when `--parallel` is supplied, so later changes to the shared `NC_PARALLEL` remain effective. Interactive initialization displays the inherited count; pressing Enter preserves inheritance, while entering a number writes an explicit override.

## Environment reference

| Variables | Purpose / default |
| --- | --- |
| `ND_URL` | HTTP inventory base URL |
| `ND_CACHE_TTL` | Inventory cache lifetime in seconds; finite positive number, default 259200 (three days) |
| `ND_USERNAME`, `ND_PASSWORD` | HTTP login without API key |
| `ND_API_KEY` | Existing API key |
| `ND_DB_HOST`, `ND_DB_NAME`, `ND_DB_USER`, `ND_DB_PASS` | Required database connection fields |
| `NC_CONFIG` | Non-sensitive YAML file |
| `NC_PARALLEL` | Default batch worker count; integer 1–500, default 4 |
| `NC_DEVICE_USERNAME`, `NC_DEVICE_PASSWORD` | Default device credentials |
| `NC_<VENDOR>_USERNAME`, `NC_<VENDOR>_PASSWORD` | Vendor credentials, e.g. `CISCO_IOS` |
| `NC_ENABLE_PASSWORD`, `NC_<VENDOR>_ENABLE_PASSWORD` | Optional privilege credentials |

Only the variables listed above are supported. There are no legacy aliases. Public settings belong in YAML: budgets under `netdisco`, filters and mappings under `inventory`, script output budget and vendor protocols under `ssh`, and source files/VRFs under `tftp`. Database port, TLS mode, CA path, and connection timeout use `netdisco.db_port`, `db_sslmode`, `db_sslrootcert`, and `db_connect_timeout`. TFTP uses `tftp.server` and `tftp.verification_root`; progress uses `--no-progress`. Removed settings and old prefixes are rejected without echoing their values. Vendor source fields are `h3c_source_file`, `h3c_wireless_source_file`, and `huawei_source_file` under `tftp`.

Scheduling and durable queues belong to the caller. No device command retries are added by batch orchestration. For development gates and evidence limits, see [verification](VERIFICATION.md); for protected extension interfaces and report helpers, see [architecture](architecture.md) (Chinese).

An interrupted batch exits with status 130 and reports `status: interrupted`. Completed artifacts retain their receipts; remaining slots distinguish `interrupted` from `not_started`. Uploads are never replayed. `events.jsonl` includes artifact metadata without configuration bodies. Library callers still receive the original `Interrupt` and may inspect `Fleet#last_report`; a new run clears that report.

The canonical parallel entry is now `net/connector/parallel/pool` / `Net::Connector::Parallel::Pool`. The former `parallel` require paths and `Parallel` namespace have been removed. Built-in TextFSM assets now reside in `lib/net/connector/textfsm/`; default parser lookup follows this automatically, while literal resource paths must be updated.

Topology comparisons preserve semantically equal existing descriptions. Set `topology.neighbor_name_prefixes: ["AP-"]` to explicitly accept a legacy name prefix during comparison; the default empty list makes no prefix assumptions. Unknown neighbor identities produce no commands, while other verified interfaces can still be planned independently.

Topology examples also export `scripts/<name>-<IP>.cfg` for verified changes and `devices/<name>-<IP>.txt` for every result, using the backup filename rules. Plans and summaries reference the files and command SHA-256. No-change, discovery and failed results have no empty command file. Export failure prevents application; exported commands do not bypass live evidence revalidation.

Topology output distinguishes unresolved evidence from execution failures and defaults to a compact Chinese summary. Use `--verbose` for per-device events. JSON keeps status codes and adds `statistics`; pending changes or unresolved evidence still exit with code 1. Startup shows the resolved configuration file: `NC_CONFIG` is also the final topology configuration layer, so shared configuration must include the appropriate `topology` policy.
