# Changelog

## v0.9.3 - 2026-11-16

- Update every explicit dependency to its current latest version, including colorprofile, ultraviolet, ANSI, go-colorful, go-runewidth and terminfo.
- Retain published go-expect v0.6.2 and Go 1.26.0.

## v0.9.2 - 2026-11-16

- Adopt published go-expect v0.6.2 to reduce receive mailbox allocations, retain progress across interrupted immediate writes and refresh test dependencies.
- Adopt published go-standards v1.2.0 and document intentional independent context lifetimes.

## v0.9.1 - 2026-11-16

- Preserve parent deadline errors when operation-scope cancellation races with timeout propagation.
- Retain elapsed archive deadlines when worker/I/O completion precedes the local context timer callback.
- Retire direct and operation-scoped device sessions when the final observer cancels the operation, while retaining accepted command receipts.
- Release archive upload callback contexts and pool preparation resources on panic or Goexit; publish preparation progress on the Prepare caller.
- Adopt published go-standards v1.1.0 and update pgx, pflag, YAML and golang.org/x dependencies while retaining Go 1.26 and the published go-expect v0.6.1 dependency.
- Validate module tidiness without requiring dependency edits to be committed before local checks.

## v0.9.0 - 2026-11-15

- Breaking: rename the Go module from `github.com/gatework/go-net-connector` to `github.com/gatework/net-connector`. Update imports and module requirements together; earlier tags retain their original module path.
- Rename release archives and the embedded application identity to `net-connector`. Command names remain `netman` and `tftp-archive`.

## v0.8.0 - 2026-11-12

- Breaking: one vocabulary. Package `vendors/dialect` is now `platform`; family types are `Platform` (`h3c.Platform`, `cisco.IOSPlatform`, …); `fleet.Record.Vendor` and `Mapping.Connector` are `Platform`; `Record.BackupFilename(style)` is `Record.Filename()`.
- Breaking: configuration keys `inventory.include_vendors`, `exclude_vendors`, `vendor_overrides`, `ssh.vendor_protocols` and `backup.limit_per_vendor` are `include_platforms`, `exclude_platforms`, `platform_overrides`, `ssh.platform_protocols` and `backup.limit_per_platform`; their `NC_*VENDOR*` variables are `NC_*PLATFORM*`; `--vendor`/`--exclude-vendor` are `--platform`/`--exclude-platform`; device rules use `platform` instead of `connector`. Old names are not recognized.
- Breaking: report schema v4. A topology plan records `platform` instead of `vendor`.
- Remove the rejection table for configuration keys deleted in v0.6.0, the API migration guide and the downstream source probe scripts.
- Breaking: capability data types live with their consumers: `topology.Neighbor`, `topology.WriteMode`, `transfer.TFTPOptions`, `transfer.TFTPEvidence` (was `TFTPReceipt`), `transfer.RemoteBackupOptions`.
- Breaking: `transfer.TFTPPolicy` is six methods; fixed requirements are `Traits() TFTPTraits`, and source-file discovery is the optional `transfer.SourceFileResolver`.
- Breaking: `fleet.PlanOptions` drops `Mode` and `AllowFixedNameReuse` for injected `Admit` and `ReuseDestination` functions; sampling now counts only devices the operation admits.
- Breaking: `connector.LoginState.HAState`/`Device.HAState()` are `LoginState.Labels`/`Device.LoginLabel(name)`; an already-privileged login prompt is declared with `Terminal.PrivilegedPrompt` instead of being inferred from a `]`.
- Breaking: `deploy run` snapshots the configuration before and after the change and writes a unified diff (`before/`, `diff/`, `artifacts.change` in the report). `--no-snapshot` turns it off; `--backup` is removed because the after-snapshot is the backup artifact.
- Add candidate-configuration deployment for Juniper Junos and Palo Alto PAN-OS: `connector.Committer`, `Operation.Commit`, `deploy run --commit-confirm <minutes>` (Junos) and `artifacts.commit` in the report. A commit counts only with the device's positive commit evidence. Not verified on real devices.
- Add `netman facts plan|run` and the `facts` package: read-only collection of model, serial number, software version and uptime for Cisco IOS/NX-OS, H3C, Huawei, Juniper and Fortinet, compared against the inventory (`artifacts.facts.mismatches`). Templates follow published command references; not verified on real devices.
- Add a local inventory source: `inventory.source: file` with `inventory.file` (YAML `devices:` list or CSV), read by the new `inventoryfile` package. An unusable or repeated address or an unknown field rejects the whole file.
- Add `netman platform list` (text or `--json`), generated from the same checks that admit devices to a batch.
- Add `connector.CanCollectConfig` and `connector.CanSave`.
- Add typed `batchreport.Status`/`Outcome`, `connector.LogLevel`, `connector.LoginCommitter` and `connector.Terminal.Clone`.

## v0.7.1 - 2026-11-11

- Adopt go-standards v1.0.2 through shared lint, architecture and make gates while retaining installed-worker, PostgreSQL, fuzz and consumer checks.
- Split configuration, execution, transfer and reporting phases without changing public APIs or delivery evidence.
- Upgrade the published go-expect dependency to v0.6.0 and use MatchOption internally.

## v0.7.0

- Add platform drivers, per-device stage pipelines, unified report schema v3 and the deploy, exec, remote backup and diff commands. See docs/releases/v0.7.0.md.
