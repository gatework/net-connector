# SSH authentication session scope

Continue the authorized eight-module review. Authentication owns one private, bounded PTY dialogue; Expect owns initialization, process resources and cleanup. Current manual `Session.new` assignment leaves initialized PTY handles unowned if cancellation arrives before assignment. Its ensure also lets an ordinary cleanup exception replace the authentication exception.

Reuse the current public `Expect.spawn(*arguments, raw: true, buffer_limit: 65_536, write_timeout: 5) { |session| ... }` lifecycle. Keep the same password matching, one answer only, private output, 15-second total dialogue budget after spawn, boolean result and caller's separate master-connection check. Do not add a lifecycle helper, compatibility branch, dependency, fallback, alternate password mechanism or logging.

Initialization cancellation must propagate the same Interrupt and close both acquired endpoints. Ordinary cleanup errors must not replace a primary IOError or Interrupt. A cleanup error without a primary failure must still propagate. Normal success/rejection must release the child and endpoints. Fresh fatal cleanup exceptions follow Expect's existing propagation contract; no new exception policy is introduced.

Only the authentication implementation, its existing focused test file, changelog and architecture description change. Chinese method comments and English implementation literals remain mandatory. Preserve WIP, work in the existing isolated worktree, and copy only hash-guarded scoped changes back. No commit/push/release. Local PTY evidence does not establish remote SSH or device compatibility.

Acceptance: regression tests first fail at observable cleanup/error boundaries; focused and complete project gates then pass with installed Expect 0.9.5; focused minimum 0.9.4 coverage passes; exact current package install and source bytes are checked. One final independent review, followed by one tested fix pass if needed. No pending question requires new user approval.
