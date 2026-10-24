# PTY cleanup ownership implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Keep failed PTY cleanup owned and block reconnect/recovery from abandoning a live child.

**Architecture:** ResourceOwner/ChildProcess stay inside Expect. Connector Pty retires a channel into one pending cleanup reference and releases it after hard_close plus the existing alive? query. Session permits transport recovery only after successful cleanup.

**Tech Stack:** Ruby 3.4/4.0, Minitest, existing project CI and isolated gem installers.

**Spec:** docs/superpowers/specs/2026-10-23-pty-cleanup-ownership.md

## Global Constraints

- Preserve all existing WIP and use an isolated worktree; no commit, push, release or workspace deletion.
- Chinese implementation comments, English implementation literals; no bulk test/doc translation.
- No new public API, dependency, retry flag, or compatibility adapter. Channel factories implement current Expect lifecycle.
- Actual-checkout and installed-artifact evidence are separate. Remote SSH and other-platform validation remain unclaimed.

## Review Focus

- Deferred cancellation after successful close versus synchronous error before completion: do not retain completed resources or lose failed ones.
- A bounded hard_close can return nil with a live PID; never clear ownership solely because no exception was raised.
- SSH reopen must not close its newly created trust snapshot while cleaning the previous PTY.
- Recovery and repeated operations must retain the failed transport until cleanup succeeds, preserving the first error.
- Nonlocal close exits and persistent cleanup failures must not create multiple channels or an unbounded retry loop.

### Task 1: retain cleanup ownership through transport and connection recovery

**Files:** lib/net/connector/engine/transports.rb, lib/net/connector/engine/session.rb, test/transport_test.rb, test/engine_boundary_test.rb, CHANGELOG.md, docs/architecture.md.

**Interfaces:** Produces an internal pending-channel lifecycle and boolean close_preserving_failure result. Consumers are Pty/Ssh open, explicit close, and Session connect_session. Public signatures remain unchanged; alive? is the current Expect Session predicate.

- [x] Add real child regression tests in transport_test: first injected wait EINVAL leaves child alive, second transport.close reaps it; persistent cleanup failure blocks factory invocation on open; later successful open reaps old PID before starting new child; hard_close returning nil while child is alive raises IOError and remains retryable. Verify every test cleans its real child in ensure. Cover nonlocal exit, SSH trust/log handoff and a forked transport copy.
- [x] Extend existing SSH dual-failure test so repeated close retries only the failed channel and preserves the original error; trust is attempted once. Existing successful deferred cancellation remains one close. Add alive? false to minimal successful fake channels to implement the actual lifecycle contract.
- [x] Add engine_boundary_test for failed connection plus cleanup IOError: original connection_refused remains, recoveries = 0, replacement opens = 0, no command writes.
- [x] Run `RUBYLIB=/Users/crate/Works/ruby/expect-ruby/lib bundle exec ruby -Itest test/transport_test.rb` and corresponding engine_boundary_test. Expected: new regressions fail with unreaped child/missing cleanup error or unexpected recovery, old relevant cases pass.
- [x] Implement internal pending ownership in Pty#close and gate Pty/Ssh#open before new resource acquisition. Keep the existing cancellation shield and first-error handling. Confirm child liveness before dropping pending channel; raise IOError `PTY child is still running after hard close` if alive.
- [x] Return true/false from Session#close_preserving_failure; connect_session skips recovery on false, keeps first connection error and transport.
- [x] Run both focused files and `RUBYLIB=/Users/crate/Works/ruby/expect-ruby/lib bundle exec rake test`. Expected: all pass, no leaked local child. Update behavior docs/changelog without version publication.
- [x] Run full connector CI, independent final review, actual-checkout gates and exact package installation with current Expect 0.9.5. Expected: all pass; final diff/hash receipt matches copied source and preserves unrelated WIP.

## Self-review and handoff

Five requirements map to Task 1 and its gates. No interface/schema migration for device results. One native implementation task and one fresh final review per executing-plans; current authorization covers reversible fixes and worktree setup. No additional approval is required. The remaining eight-module goal is not redefined by this phase.
