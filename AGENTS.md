# Go net-connector

Follow [the gatework Go engineering standard](https://github.com/gatework/go-standards/blob/v1.1.0/STANDARD.md) (go-standards/STANDARD.md); this file adds the connector-specific contracts. Run `make check` before committing.

Use the golang-how-to skill for Go implementation, review and debugging.

- Preserve reference workspaces and concurrent edits. No commits, publication or deployment without explicit authorization.
- A platform is a connector.Driver: Terminal declares CLI grammar, driver methods carry vendor behavior; consumer-owned interfaces declare optional vendor capabilities. Device owns its operation lease and session; transport owns processes; go-expect owns stream matching and I/O.
- Validate complete scripts before connection or sending. Never replay device writes after an uncertain result.
- Preserve completed steps and storage commit receipts when later logging, callbacks or durability fail.
- Raw responses are explicit access only; diagnostic formatting must not expose secrets or response bodies.
- Test actual byte sequences and failure boundaries. Test success does not imply real-device or remote-release evidence.
- New APIs use context, bounded resource ownership and explicit dependency injection. No global service locator.
- Follow docs/design.md and record implementation evidence in docs/progress.md.

- Resolve go-expect from its pinned GitHub module with GOWORK=off. Frozen sources/patches are historical; do not reintroduce a local dependency replacement.
- Device.Close is terminal and cancels active operations without waiting for user callbacks. Failed sessions need explicit Connect before another command.
- Preserve failed Attempt evidence separately from accepted Steps. Save completion requires Driver.ValidateSave; a prompt alone is unconfirmed.
