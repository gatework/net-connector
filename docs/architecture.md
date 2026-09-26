# Device operations model

The public connector object represents one device session. It owns connection state,
command execution, and the vendor profile. Callers continue to use
`device.running_config`, `device.backup(path:)`, and `device.tftp_backup(...)`.
Running configuration is a basic device capability: `device/` owns the facade,
immutable profile, and shared collection flow. `Net::Connector::Operations`
groups optional workflows over that device: backup, parsing, neighbor discovery,
and interface description plans. Saved-file export is a local operation and
does not open a device session.

| Layer | Responsibility | Location |
| --- | --- | --- |
| Device session | Login, command dialogue, script execution, logging | `engine/` |
| Device | Public facade, immutable profile, collection and interface naming helpers | `device/` |
| Vendor assembly | Static CLI prompts, commands, interactions, strategy bindings and session hooks | `vendor/<name>.rb` |
| Configuration collection | Shared execution, completeness checks and hook adaptation | `device/running_config.rb`, `device/running_config/strategy.rb` |
| Vendor collection | Configuration cleanup, view transitions and response checks | `vendor/<name>/running_config.rb` |
| Interface text | Name matching, optional abbreviations, description formatting and common interface-view commands | `device/interface_name.rb`, `device/interface_description.rb` |
| TextFSM parsing | Select a template and parse command output or saved configuration into records | `operations/parse_output.rb`, `templates/` |
| Topology and description plan | Read CDP/LLDP neighbors and current descriptions, prepare commands, recheck evidence before confirmed execution | `operations/topology.rb` |
| Local backup | Collect, compare hashes, atomically save, report change | `operations/local_backup.rb` |
| Saved configuration export | Find and export an existing local backup without inventory access | `operations/saved_config.rb` |
| Private file write | Atomically replace local backup and export files with mode `0600` | `operations/private_file.rb` |
| TFTP backup | Validate target, run export, check transfer evidence, report result | `operations/tftp_backup.rb` |
| TFTP vendor strategy | Export command, prompts, source file, success evidence, remote name | `vendor/<name>/tftp_backup.rb` |
| Topology vendor strategy | Discovery commands, parsing evidence, configuration views and command exceptions | `vendor/<name>/topology.rb` |
| Inventory plan | Select ready devices, apply per-vendor limits, record skip reasons | `netdisco/planner.rb` |
| Batch worker | Dispatch independent device jobs and isolate callback failures | `netdisco/worker.rb` |
| Batch result | Summarize outcomes and preserve report failures | `netdisco/batch.rb` |
| Fleet | Load inventory, run local or TFTP tasks, write reports | `netdisco/fleet.rb` |
| Settings | Read environment and YAML overrides for CLI and fleet | `netdisco/settings.rb` |

## Business contracts

The connector facade owns one session. `Session` serializes login and scripts,
closes the transport on failures, and never replays a device command. Each
`Result` retains completed steps on failure. `RunningConfig` executes one
collection script with one fresh strategy per call. Response checks, step
selection and cleanup share that strategy. Selection and cleanup run through
the existing facade hooks while the session lock is held; overridden methods
can call `super`. The temporary binding is released even when cleanup fails,
and is not available to other Fibers performing offline cleanup. Collection
commands use the current session's complete prompt line, not a generic trailing
`#`, `>` or `]`. PAN-OS view transitions preserve the authenticated prompt identity.
A missing final prompt fails collection and leaves the previous backup untouched. Missing or blank configuration, including a response containing
only a prompt or command echo, is `:incomplete_configuration`,
not a successful empty backup. PAN-OS checks the candidate diff both before and
after its `show` command.

`LocalBackup` collects before replacing a private file and preserves the old
file on failure. TFTP reports only device-side completion. Its strategies check
explicit completion lines after removing command, reply and prompt echoes;
filenames and future-tense progress do not establish success. Failure evidence
from raw and rendered output takes precedence over completion messages. `Topology` reads
neighbors and descriptions, freezes a plan, requires explicit confirmation,
rechecks evidence, rebuilds the commands, and reads the configuration back.
The complete recheck/write/readback sequence holds a session operation lease.
Sequential scripts from its owning thread and Fiber may execute; other callers,
close attempts and reentrant script callbacks receive `SessionBusy`. This lease
is local to one connector instance, not a device-side or cross-process lock.
`Fleet` keeps skipped, failed, successful, and saved-with-close-error outcomes
distinct; callback and report errors remain visible without discarding device
results. Neighbor table headers alone can establish an empty table, but unknown
or partly parsed rows cannot establish a complete discovery result. Diagnostics
are checked against both original output and terminal-rendered text so that
color sequences cannot hide failures and carriage returns cannot erase them.
Plan revalidation compares the complete discovered neighbor, including chassis
ID when available, without changing the public evidence hash shape. PAN-OS
configuration collection preserves multiline quoted values, but the interface
description template supports single-line comments only; incomplete quoted
comments raise `ParsingError` instead of becoming truncated plan evidence.

## Expect semantics and Ruby boundaries

The [Tcl Expect manual](https://core.tcl-lang.org/expect/doc/trunk/expect.man)
defines ordered matching, `exp_continue -continue_timer`, buffer consumption,
EOF, and separate close/wait responsibilities. Its
[matching loop](https://github.com/tcltk-depot/expect/blob/main/expect.c)
keeps the deadline when `EXP_CONTINUE_TIMER` is returned; its
[process handling](https://github.com/tcltk-depot/expect/blob/main/exp_command.c)
waits for the owned child and retries interrupted waits. These are useful
reference semantics; `net-connector` is a device operations library, not a Tcl
interpreter or a complete Expect API port.

| Concern | Connector contract | Owner |
| --- | --- | --- |
| Matching | Connection failures precede interactions, then the final prompt; prompt matches must consume bytes | `ResponseReader` |
| Time | One monotonic deadline includes command writes and prompt replies; progress and pagination never extend it | `Session`, `ResponseReader` |
| Buffers | Preserve collected output up to `max_output_bytes`; retain 32 KiB of unmatched tail while streaming larger output | `Transports::Pty`, `ResponseReader` |
| EOF | Return `ConnectionClosed`, preserve earlier completed steps, close the session | `ResponseReader`, `Execution`, `Session` |
| Resources | Own the child through `expect-pty#hard_close`; release log files even after setup or flush errors | `Transports::Pty`, `Log` |
| Interactive use | A manual interaction ends the automated session; subsequent work creates a fresh connection | `Session` |
| Concurrency | One script or multi-script operation owns a device session; callbacks cannot reenter it; independent jobs use a bounded worker pool | `Session`, `Netdisco::Worker` |

Patterns are Ruby regular expressions. Keep custom prompts and interaction
markers short enough to fit the unmatched tail; a pattern requiring an
arbitrarily long transcript is not supported by the streaming adapter. Output
collection and the matching window have different limits. The terminal renderer
handles common line-editing controls, not a full screen terminal emulator.
`Profile#terminal_size` uses `[width, height]`; the PTY adapter converts it to
Ruby's `[rows, columns]` convention.

Ruby objects retain explicit resource ownership and keyword arguments.
`Profile` provides finite declarations; strategies contain vendor behavior.
Private guards use direct names such as `check_block!` and
`check_change_support!`. Public methods, vendor hooks, result objects, and CLI
JSON fields remain stable. There is no runtime method injection or workflow DSL.

## Vendor capabilities

`device.supports?(capability)` reads the profile and method-based collection
commands without opening a transport or constructing a strategy. Accepted
capabilities are `:running_config`, `:save_config`, `:backup`, `:tftp_backup`,
`:neighbors`, `:interface_descriptions`, and
`:interface_description_changes`; unknown names return `false`. This reports
implementation support, not device authorization or firmware compatibility.

| Vendor | Collect / local backup | Save | TFTP | Neighbors | Descriptions | Plan and apply descriptions |
| --- | --- | --- | --- | --- | --- | --- |
| H3C | Yes | Yes | Yes | Yes | Yes | Yes |
| H3C wireless | Yes | Yes | Yes | Yes | Yes | Yes |
| Cisco IOS / IOS XE | Yes | Yes | Yes | Yes | Yes | Yes |
| Cisco NX-OS | Yes | Yes | Yes | Yes | Yes | Yes |
| Radware Alteon | Yes | Yes | Yes | No | Yes | No |
| PAN-OS | Yes | No | Yes | Yes | Yes | Yes |
| Huawei | Yes | Yes | Yes | No | No | No |
| Hillstone | Yes | Yes | Yes | Yes | Yes | Yes |

The `Profile` DSL declares static command, prompt, interaction, and strategy
bindings. Configuration, TFTP and topology rules live beside their vendor under
`vendor/<name>/`. The shared collection flow and operations own validation,
execution and result semantics. Identical rules are reused directly: NX-OS uses
IOS topology rules, H3C wireless inherits H3C, and H3C/Huawei/Radware use the common
rendered configuration strategy. A directory is not a reason to copy a rule. A subclass inherits and may replace these bindings.
Setting a TFTP or topology binding to `nil` disables that capability. A `nil`
collection binding uses the default strategy; an empty collection command list
disables collection. For example, a model variant can replace its transfer flow:

```ruby
require "net/connector"
require "net/connector/vendor/cisco_ios"

class VariantTransfer < Net::Connector::CiscoIos::TftpBackup
  # Override only the methods needed by this model; preserve the Strategy API.
end

class VariantRouter < Net::Connector.vendor_class(:cisco_ios)
  profile do
    tftp_strategy VariantTransfer
  end
end

router = VariantRouter.new(host: "192.0.2.10", username: "operator")
router.supports?(:tftp_backup) # => true, no connection attempted
```

For collection, bind `running_config_strategy` to a subclass of
`Net::Connector::RunningConfig::Strategy`. The strategy defines cleaning, result-step
selection, expected view transitions and per-response validation. PAN-OS candidate
diff checks apply only to collection; a direct `execute("show config diff")` still
returns the requested output. Static command lists stay in the profile. The
facade's `collect_config`, `clean_config` and protected `config_result_step` hooks
remain available for existing subclasses. `Base` runs generic scripts and locked
callbacks; it does not decide whether a configuration is complete.

For topology, bind a subclass of `Operations::Topology::Strategy` (or an
existing vendor strategy) with `topology_strategy YourStrategy`. Its static
`supports?` declares which of the three topology operations it implements;
the instance methods provide commands, templates, output completeness, and
interface spelling. A vendor using a custom inventory label must also provide
a TextFSM template through `neighbor_template`, because the bundled index
matches the existing vendor keys. Keep confirmation, evidence checks, and
readback in `Topology`.

Device operations are constructed for one connector and have a `call` method. TFTP
strategies contain only device-specific transfer behavior; the operation owns
the shared success and failure rules. Each vendor binds its strategies in its
profile, so adding a backup operation does not add methods to every vendor
connector. Generated TFTP filenames share `TftpTarget` validation and length
limits. Scoped IPv6 addresses become safe ASCII filename tokens; an unusually
long address uses a stable SHA-256 token. Existing valid filenames retain their
spelling, and inventory labels are shortened only when the complete name would
exceed the target limit.

The facade keeps the existing device API while allowing batch workers and
single-device callers to share the same operations. The TFTP result means the
device reported upload completion; checking the server file remains the
caller's responsibility.

The acceptance gate is `script/ci` (also `bundle exec rake release:check`). It
checks source, available Git history and gem contents for sensitive data; runs
Ruby and workflow lint and the full test suite; and installs the gem into both
an isolated gem home and a minimal Bundler application. A local PTY smoke checks
vendor loading, configuration collection, packaged TextFSM templates and the CLI.
RuboCop checks Ruby lint, security, whitespace, frozen string comments and the
project's double-quoted string convention. No real device is contacted. Initial
dependency and tool downloads require internet access; see
[verification](VERIFICATION.md) and [release instructions](RELEASING.md).

## Loading and compatibility

`require "net/connector"` loads the device API and engine, without loading vendor
rules or TextFSM. Each vendor entry point assembles only its own rules and shared
parents. Parsing loads when a parsing or topology workflow is used. Lower-level
callers can load `net/connector/engine/core` without device definitions, business
operations or vendor rules. `engine/base`, `engine/profile`, and `engine` remain
forwarding entry points for existing callers.

Old `Operations::RunningConfig`, `Operations::RunningConfig::<Vendor>`,
`Operations::Tftp::<Vendor>` and `Operations::Topology::<Vendor>` constants and
require paths forward to the same classes, rather than maintaining duplicate
implementations. Existing public result constants also remain available through
autoload. New vendor code uses the vendor-owned classes directly.

## Interface description policy

Raw `Neighbor` fields and plan evidence retain the exact discovered values.
`InterfaceName.key` matches local aliases to running configuration names;
`InterfaceName.configuration` preserves the established CLI expansion rules.
`InterfaceName.short` is exclusively a display policy for the remote port in a
description. It never replaces the local interface used in commands.

`InterfaceDescription.format(neighbor, abbreviate: true, lowercase: false)` is
shared by every vendor's default plan. It retains the neighbor device name and
produces `To <name> <port>`. Known families shorten as follows, preserving lower,
upper or initial-capital case: Ethernet/Eth → Eth, GigabitEthernet/GE/Gi → Gi,
Ten-GigabitEthernet/TenGigabitEthernet/XGE/Te → Te, FastEthernet/Fa → Fa, and
port-channel/Po → Po. Port numbers and subinterface suffixes stay intact. Unknown
forms such as `ge-0/0/1`, `100GE1/0/1` and `Port 12` stay unchanged by default;
this is a finite mapping, not a claim to recognize all vendors or interface types.

This changes the default proposal from `To peer Ethernet1/2` to
`To peer Eth1/2`. Use `plan_interface_descriptions(abbreviate: false)` to keep the
previous spelling, or `lowercase: true` to lowercase only the remote interface.
An explicit formatter block receives the original neighbor and controls the
complete description. All outputs still pass the same 80-byte and character
validation, evidence recheck, confirmation and readback requirements.

`InterfaceDescription.commands(interface:, description:, leave: "exit")` builds
separate `interface`, `description` and exit commands for IOS/NX-OS and Hillstone;
H3C supplies `leave: "quit"`. Entering configuration mode and saving remain
vendor responsibilities. PAN-OS retains `set network interface ... comment`,
`commit`, and its extended commit timeout. The common builder is pure: it does
not send commands or bypass the reviewed topology plan.

## Sensitive command lifetime

One temporary redaction scope spans preparation, exchange, vendor postprocessing,
user callbacks and error normalization. Follow-up queries share the enclosing
scope; `ensure` removes temporary secrets afterward. Sensitive errors preserve
type, code, phase and completed steps but hide arbitrary messages, output and
underlying backtraces that could contain partial secrets. Explicit result data
remains raw. Direct and streaming redaction prioritize actual secrets, including
secrets containing the literal `[REDACTED]`, before preserving existing markers.

## Local backup identity and legacy files

Fleet backups use the normalized management IP alone (`<IP>.txt`, with IPv6 `:`
replaced by `_`). Inventory names remain result metadata and TFTP labels.
`SavedConfig` prefers this canonical file. If absent, it accepts exactly one
legacy `<name>-<IP>.txt` file; multiple matches fail rather than choosing by mtime.
The first successful canonical backup compares against the unique legacy digest,
retains the legacy file, and reports `changed` or `unchanged` accordingly. Failed
collection creates no canonical file. Symlinks and non-regular candidates are
rejected before connecting. Existing ambiguous legacy sets need operator review:
retain the originals and place the verified current configuration at the canonical
path before resuming backup/export.
