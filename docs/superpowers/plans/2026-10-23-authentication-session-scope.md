# SSH authentication session scope implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Reclaim partially constructed authentication sessions and preserve primary authentication failures.

**Architecture:** Authentication borrows the session yielded by the existing Expect.spawn block factory. Expect retains all construction, process and cleanup ownership; Authentication keeps the password dialogue.

**Tech Stack:** Ruby 3.4/4.0, Minitest, expect-pty >= 0.9.4, project Bundler and CI.

**Spec:** docs/superpowers/specs/2026-10-23-authentication-session-scope.md

## Global Constraints

- Preserve WIP; use the existing isolated worktree and hash-guarded copy-back. No commit, push or publication.
- Chinese method comments, English lib literals; no bulk test/doc translation.
- Keep raw PTY, buffer_limit 65_536, write_timeout 5, one answer, privacy and existing 15-second dialogue budget; no public signature or dependency changes.
- Actual source, minimum dependency, isolated packages and remote-device evidence are distinct.

## Review Focus

- Cancellation at completed initialization before caller assignment closes acquired handles and preserves the original interruption.
- Ordinary cleanup failure after authentication failure preserves the primary exception; without a primary failure it must propagate.
- Rejected/repeated password prompts produce false, never another password write or a successful master-connection claim.
- Block conversion must preserve deadline, output privacy and cleanup on nonlocal exits.
- Partial spawn and fatal cleanup must follow the existing Expect contract, without duplicated cleanup or swallowed fatal exceptions.

### Task 1: use the current owned session scope

**Files:** lib/net/connector/netdisco/ssh/authentication.rb, test/ssh_authentication_test.rb, CHANGELOG.md, docs/architecture.md.

**Interfaces:** Consumes Expect.spawn block API and Session.expect/write. Produces unchanged Authentication.respond(arguments, password:) boolean or original failure; Archive::Client remains the caller responsible for checking the master connection.

- [x] Add `test_cancelled_session_construction_reclaims_its_terminal_handles`: TracePoint at Session initialize return raises a specific Interrupt; assert that object propagates and reader/slave close. Ensure the probe cleans up on failure.
- [x] Add `test_authentication_error_is_not_replaced_by_ordinary_cleanup_error`: real local PTY, injected write IOError and Interrupt, cleanup performs its real close then raises IOError; assert original identity and released process/handles. Add the corresponding successful-dialogue cleanup-error propagation guard.
- [x] Run `bundle exec ruby -Itest test/ssh_authentication_test.rb`. Expected: construction/primary-failure regressions fail against current implementation; baseline privacy/one-answer behavior and no-primary-error guard pass.
- [x] Replace manual Session construction/spawn/ensure with the specified Expect.spawn block. Use block-local false for rejection, keep existing dialogue body and constants. Expected: no new lifecycle state or exception rescue.
- [x] Run focused tests, minimum-dependency focused tests and lint; update changelog/architecture. Run `bundle exec rake test`. Expected: all green, every test child reclaimed.
- [x] Dispatch one fresh independent review of this phase diff, spec and ledger. Resolve valid Critical/Important findings in one RED/GREEN fix pass; log other rulings. No second review.
- [x] Hash-check and copy scoped changes to the actual checkout, then run `CTX_CLI_GEM=<verified candidate> bash script/ci` and exact-package verification with authentication lifecycle probes. Expected: all green, installed source bytes match, unrelated WIP preserved.

## Self-review

All requirements and review focus map to Task 1. Existing tests cover privacy, rejection, repeat challenge and archive policy; new regressions target missing ownership and error priority. Expect's own complete current gate covers its internal spawn/fatal-cleanup contracts; connector integration and minimum-dependency tests establish this consumer boundary. Existing continuous implementation authorization supplies the execution choice and allows these reversible fixes.
