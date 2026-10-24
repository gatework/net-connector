# Archive streaming implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline; one independent final review, one fix pass, no re-review.

**Goal:** Bound Ruby/Python archive memory while preserving remote/local commit evidence and no-replay semantics.
**Architecture:** Protocol owns framing; Client owns transaction outcomes; AtomicFile owns publication; worker streams pinned files.
**Tech Stack:** Ruby 3.4+, Minitest, Python 3 standard library, real local pipes and files.
**Spec:** `docs/superpowers/specs/2026-10-24-archive-stream.md`

## Global Constraints

- 64 MiB payload, 64 KiB chunks, 16 KiB control frames, 280-second shared archive-delivery deadline; keep session concurrency unchanged.
- Chinese implementation comments, English business strings; no old private protocol branch, new runtime dependency, commit/push/release.
- Preserve actual checkout WIP and prior KnownHosts/receipt work; explicit artifact/source hashes and terminal test results.

## Review Focus

- Header/body/trailer may arrive together, binary body can contain JSON-looking bytes or newlines; Task 2 exercises exact framing.
- An invalid size/type/hash cannot cause unbounded reads or publication; Tasks 2/3 cover rejected metadata and body faults.
- Disk failure before or during streaming must retain verified server evidence without retrying writes/upload; Task 3 covers both timings.
- File identity changes during worker copy/delivery or before cleanup must not be accepted; Task 3 uses existing pinned-directory cases and new stream mutation probes.
- Exceptions, Interrupt, throw and post-rename persistence errors retain cleanup/commit boundaries; Tasks 1/3 cover these explicitly.

### Task 1: Stream through the atomic publisher

**Files:** `lib/net/connector/storage/atomic_file.rb`, `test/file_persistence_test.rb`.
**Interfaces:** Add `AtomicFile.write_stream(path) { |file| ... } -> Receipt`; `write(path, contents)` delegates to it; error codes and Receipt fields unchanged.

- [x] Add tests using actual files: chunks including binary bytes become visible only on block success, standard block failure leaves old file with not_committed/write receipt, Interrupt and throw leave old file and no temporary file.
- [x] Run `bundle exec ruby -Itest test/file_persistence_test.rb`; Expected: new write_stream cases fail before implementation.
- [x] Move existing transaction body to write_stream, yield temporary file at write phase, keep validation/fsync/rename/error handling; make write delegate.
- [x] Run same command; Expected: all existing and streaming persistence tests pass.

### Task 2: Bound protocol framing and deadlines

**Files:** new `lib/net/connector/netdisco/ssh/archive/protocol.rb`, new `test/ssh_archive_protocol_test.rb`.
**Interfaces:** `Protocol.new(input, output, timeout: 280)`, `send_frame(**values)`, `expect_phase(phase) -> Hash`, `read_payload(length) { |chunk| ... }`; read_payload consumes delivered using the archived deadline. Does not close IO.

- [x] Add real pipe tests for fragmented/coalesced control/body/trailer and binary bytes; oversize/control types, payload size bounds, EOF/extra bytes, wrong phase and fixed deadline.
- [x] Run `bundle exec ruby -Itest test/ssh_archive_protocol_test.rb`; Expected: fail before Protocol implementation, then pass after implementing bounded buffer/reads and trailer verification.

### Task 3: Stream client and worker with truthful receipts

**Files:** `lib/net/connector/netdisco/ssh/archive/client.rb`, `worker.py`, `test/ssh_archive_client_test.rb`, any existing persistence consumer assertion that injects the replaced write boundary.
**Interfaces:** Client uses Task 2 per transaction and Task 1 for local publication. Worker emits the exact private protocol from spec; existing public Client/Outcome/TftpReceipt signatures unchanged.

- [x] Add end-to-end cases for binary/multichunk upload, faulty metadata/length/hash/trailer, local prepare/create/write/sync failure and cancellation; assert no replay, old local file/staging preserved and server/local receipts by phase. Add worker bounded-read and changed-file probes.
- [x] Run archive client tests; Expected: new streaming cases fail with the old protocol. Preserve RED evidence.
- [x] Replace whole-body worker read/copy/digest with bounded reads and identity checks; send metadata + raw archive bytes + delivered. Client verifies while writing, drains after local storage failures when possible, publishes only after verified body/trailer, and uses trusted write receipts after commit.
- [x] Run archive client/pool and persistence tests, then `bundle exec rake`; Expected: all pass, no weakened failure assertions.

### Task 4: Measure, review and deliver

**Files:** `CHANGELOG.md`, `docs/architecture.md`, benchmark artifacts in `.ctx-archive-stream-20261024`; existing synthetic baseline remains immutable.
**Interfaces:** Same five workloads and correctness assertions as `.ctx-archive-memory-20261023`; use selected source paths and getrusage(RUSAGE_SELF).

- [x] Run fifteen optimized samples and compare memory, time and allocations with baseline; Expected: no whole-body memory growth, all archive assertions pass. Record actual values, no network claims.
- [x] Guard-copy scoped changes to actual checkout; run actual `bash script/ci` with exact current CLI candidate and ordinary archive probe. Expected: all gates exit 0.
- [x] Build and verify current package; ordinary/Bundler installed stream/failure probes and all packaged bytes match. Expected: exit 0.
- [x] One independent final review of exact phase diff/spec/ledger; fix substantive findings once via RED/GREEN and full gates. Expected: no unresolved substantive finding.
- [x] Verify all scoped hashes, unrelated WIP, language, package and benchmark provenance; update phase report and overall module ledger. Keep overall goal active until separate completion audit proves the full scope.
