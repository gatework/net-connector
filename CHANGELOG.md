# Changelog

## Unreleased

## 0.4.0 - 2026-09-26

- Redact dynamic login challenge failures before logging or capturing their underlying exceptions, including partial credentials and backtraces.
- Keep PAN-OS LLDP discovery usable when some local interfaces have no neighbors, while rejecting incomplete nonempty records.
- Stop remaining batch workers after an interruption, close incomplete command sessions, and use unique directories for concurrent example backups.
- Detect additional network device credential syntax before publishing, including privileged IOS usernames and hashed local passwords.
- Add shared local/CI checks on Ruby 3.2–4.0 for Linux and macOS, pinned workflow tooling, isolated gem installation, and a real local PTY smoke test.
- Require `expect-pty` 0.3.1 or later in the 0.3 series, declare directly used standard-library gems, and keep development dependencies compatible with Ruby 3.2.
- Add artifact-preserving local and manual CI release scripts with version, changelog, Git, metadata, file-byte and remote-checksum verification.
- Scan source, available Git history and the built gem for credentials and private network addresses; redact reports, replace example addresses and credential placeholders, and ignore local configurations, backups, logs and credentials.
- Make running configuration a device capability under `device/`; move the facade and profile there, and bind one collection strategy per call while preserving inherited method hooks and configuration bytes.
- Co-locate vendor collection, TFTP and topology rules under `vendor/<name>/`; retain old require paths and constants as forwarding aliases, and load vendors and TextFSM only when needed.
- Share interface name matching, description formatting and interface-view command construction. Description plans now abbreviate known neighbor ports by default while preserving case; `abbreviate: false` retains previous formatting and `lowercase: true` is opt-in. Raw evidence, local command names, confirmation and readback remain unchanged.
- Bind collection to the complete known session prompt so configuration descriptions cannot terminate a response early; incomplete responses preserve existing backups.
- Require explicit TFTP completion messages, excluding command/reply/prompt echoes and retaining failure evidence across terminal edits.
- Keep temporary secrets through command preparation, postprocessing, callbacks and exception normalization; redact secrets containing `[REDACTED]` in direct and streaming output.
- Hold one session operation lease across topology revalidation, changes and readback while rejecting nested callbacks and concurrent callers.
- Use normalized management IPs for local backup filenames, preserving rename baselines and unique legacy-file compatibility without deleting old files.

- Reject zero-width prompt matches so an old prompt cannot complete a later command, and map declared terminal width/height to PTY rows/columns correctly.
- Reject prompt-only and command-echo-only configuration responses while preserving completed steps and existing backup files.
- Reject unknown H3C/Hillstone neighbor rows instead of treating partial output as an empty or complete table; ignore H3C discovery command echoes in TextFSM parsing.
- Recheck complete neighbor identity, including chassis ID, before applying description plans and reject truncated PAN-OS multiline comment evidence.
- Recognize colorized command and TFTP failures while retaining failures overwritten by terminal controls.
- Share safe TFTP filename generation and length limits between direct operations and inventory batches, including scoped IPv6 addresses.
- Close log files when initialization fails and clear owned log state after close failures.
- Simplify the private Profile block guard to `check_block!` and document Expect semantics and resource ownership.

- Bind vendor TFTP and topology strategies through the existing Profile DSL, and expose read-only `supports?` capability queries.
- Keep configuration collection in one locked execution path, including PAN-OS step selection; reject missing, blank, or invalid cleaned configuration as incomplete.
- Move vendor-specific topology commands, parsing evidence, interface spelling, and commit rules into strategies while retaining plan revalidation and readback.

- Redact configured credentials across log chunks and terminal rendering, reject raw application loggers consistently, and release stale session state before reconnecting.
- Commit PAN-OS interface descriptions before leaving configuration mode and parse NX-OS indented descriptions correctly.
- Keep TFTP preview filenames consistent with execution and avoid treating diagnostic words inside filenames as transfer failures.
- Suppress sensitive underlying Netdisco exceptions and preserve empty or invalid-inventory outcomes in backup examples.

- Reject inconsistent inventory plans before device I/O, preserve immutable device snapshots, and require a backup artifact before reporting success.
- Mark empty backup batches as `no_devices` and reject `--host` addresses absent from the inventory.
- Reuse the private atomic file writer for batch JSON reports.
- Use Active Support tagged logging for session events, with debug device output in the same log file.
- Separate vendor CLI profiles from configuration collection, local backup, and TFTP export operation objects.
- Move each vendor's TFTP command, prompt, source-file, and completion rules into a dedicated transfer strategy.
- Add a backup CLI with safe non-secret YAML settings, effective-config display, inventory preview, targeted runs, and TFTP batch execution.
- Export an existing local device configuration to stdout or a private file without reconnecting to Netdisco or the device.
- Compare local configuration backups by SHA-256, preserve unchanged files, and expose created/changed/unchanged states.
- Add per-device start and result callbacks plus change-only notification callbacks, with isolated callback failures and task timing.
- Share batch worker and device lifecycle handling between local and TFTP backups.
- Use `vrf:` for NX-OS and Hillstone device exports, and per-vendor `vrfs:` for fleet exports.
- Move Netdisco batch planning and worker dispatch out of the examples; keep device failures independent.
- Add batch execution summaries with private JSON reports by default and an injected database repository option.
- Add Hillstone StoneOS running-configuration collection and native startup-configuration TFTP export.
- Complete Radware Alteon TFTP prompts for `.tgz` filename, private-key choice, and `mansync`.
- Distinguish explicit device-side TFTP failures from transfers without a success confirmation.
- Add configurable session log levels, readable login and command events, full debug device output, and TFTP outcome events.
- Render session events as human-readable Chinese actions with local timestamps, while retaining full device output at debug level.
- Add concise per-device TFTP results to the end of each session log.
- Match the observed PAN-OS TFTP export command order and require a positive `Sent ... bytes` completion line.
- Allow full-inventory TFTP batches with 50 workers while preserving per-device outcomes and PAN-OS filename-collision protection.
- Discover H3C startup paths from each device, recognize completed TFTP progress, and support host-specific Netdisco connector overrides.
- Add a session-log review for full TFTP batches without rewriting original outcomes.

## 0.3.0

- Add device-initiated native TFTP backup with vendor-specific commands and transfer checks.
- Save Netdisco backups as sanitized `<device name>-<IP>.txt` files for easier lookup.
- Render terminal carriage returns in H3C and Huawei configuration backups.

## 0.2.0

- Move shared connector implementation into `engine/` and remove the obsolete top-level core files.
- Add a standalone Netdisco client with validated inventory pagination and legacy query support.
- Map discovered devices to connector profiles with configurable selection and mapping rules.
- Run bounded concurrent backups with environment-backed credentials, paths, and per-device outcomes.

## 0.1.0

- Initial standalone connector with SSH and Telnet sessions, script execution, configuration collection, logging, and seven vendor profiles.
