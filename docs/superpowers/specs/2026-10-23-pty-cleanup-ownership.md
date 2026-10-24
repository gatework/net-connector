# PTY cleanup ownership

## Evidence and scope

Current expect-pty 0.9.5 passed its full local CI (634 tests, 11779 assertions). Its ResourceOwner retains failed handles and PID for another close. A real local child ignoring HUP/TERM plus one injected wait failure demonstrates that connector Pty drops its channel before hard_close, so a second connector close never attempts cleanup and the child remains alive. Source/probe evidence is in `.ctx-pty-audit-20261023` outside the checkout.

Fix the owning connector adapter and connection recovery. Expect owns the IO/PID ledger and process policy; connector owns the Expect channel until cleanup is confirmed. Keep its factory and transport boundaries; no new public API, compatibility branch, option or dependency. Inspect current Expect architecture without rewriting already sound components.

## Required behavior

1. Closing retires the active channel immediately: `closed?` is true and protocol operations cannot keep using it. The retired channel remains strongly owned until hard_close returns and `alive?` confirms no owned process remains. Ordinary errors, synchronous fatal errors, nonlocal exits and a bounded close with a live child retain the cleanup obligation. A forked transport copy closes inherited handles without waiting for the parent process's child; remember the channel-acquiring process ID without owning PID logic.
2. A later explicit close retries the same pending channel. A completed channel is not closed again. Deferred cancellation arriving after successful cleanup retains no stale obligation. Preserve the first observed error/cancellation through secondary cleanup failures.
3. Reopening finishes any active or pending channel first, before constructing a new one. SSH finishes old channel/trust before obtaining a new trust snapshot. Failed cleanup prevents opening a new process. The existing one-shot trust snapshot cleanup contract stays unchanged.
4. A failed connection may select recovery only after previous transport/log cleanup succeeds. Cleanup failure keeps the old transport reachable and the original connection error authoritative. No automatic device command replay.
5. Use real local PTY tests for child retention/reaping and bounded-close failure. Reuse existing cancellation, trust cleanup, failed startup, short write, deadline and complete local gates. Verify current 0.9.5 source and installed package separately from historical 0.9.4.

## Decisions and limits

Retain a single `@closing_channel` in the transport; it is cleanup-only and must never coexist with a newly published active channel. A boolean cleanup result in Session determines whether recovery may replace its owned transport. Clearing every reference before close is rejected because it relies on GC for live processes after an error. Do not move PID logic into connector or change Expect's bounded close semantics. Channel factories implement current Expect lifecycle (`hard_close`, `alive?`); no optional-method fallback.

Chinese implementation comments and English business literals; tests/docs are not translated. Existing WIP is preserved. No commit, push or publication. Local tests do not prove remote SSH/device compatibility or other platforms.
