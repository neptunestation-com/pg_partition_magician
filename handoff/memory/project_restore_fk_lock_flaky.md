---
name: restore-fk-lock-flaky
description: "bench/restore_fk_lock.sh's overlap race: root-caused (the fixed restore is 4.4 ms) and FIXED in #416/PR #418, merged 2026-09-22"
metadata:
  node_type: memory
  type: project
  originSessionId: e50e8cc1-f284-4544-aaec-cc7bc866c442
  modified: 2026-09-22T20:31:48.435Z
---

**RESOLVED 2026-09-22** -- issue #416, PR #418, squash-merged `c4e79a7`. Kept because the root cause
is a reusable lesson about this repo's `bench/` probes, not because the guard is still broken.

`bench/restore_fk_lock.sh` used to fail intermittently with `at least one write landed inside it got
false` against correct code (seen 2026-09-13 and 2026-09-22). **Root cause, measured on PG 17.11
against the guard's own fixture: the FIXED `restore_incoming_fks` takes 4.4 ms.** It is one `ADD
CONSTRAINT ... NOT VALID`, and `NOT VALID` does not scan. The probe polled `pg_stat_activity` until
it saw the restore active and only THEN started writing, so it was trying to catch a 4 ms window by
polling, and lost that race intermittently.

It also had a witness that could not fail: `saw := true` sat AFTER the spin loop
(`for i in 1 .. 2000000 loop exit when exists(...); commit; end loop; saw := true;`), so it was set
whether the loop found the restore or exhausted two million iterations having seen nothing.

**The fix, and the shape worth reusing:** a GATE made the ordering structural rather than raced. The
probe starts writing and announces itself, the restore does not begin until that lands, and the probe
does not stop until the restore finishes, so the probe's write span CONTAINS the window and nothing
has to be caught. Each attempt and the restore record the INTERVAL they occupied and the guard
requires a genuine interval overlap (intervals, not start instants, so an attempt that began before
the window and blocked into it still counts). Measured after: fixed code 5/5 with 22-32 of ~800
attempts overlapping; `restore_fk_inline_validate` still fails it (221.8 ms, 4 timeouts); a
deliberately sabotaged copy reports `0 of 300 attempts overlapped` and FAILS the witness -- while
"writes are not blocked" passes there, the vacuous green the old guard called success.

**Why:** this is the CLAUDE.md rule "check your instrument's cost against the window's width before
trusting it" biting for real. See [[feedback_deterministic_isolation_over_timing_races]] -- the gate
is exactly that lever.

**How to apply:** when a `bench/` probe polls for a state and then measures, first MEASURE how long
that state lasts. If it is milliseconds, the probe cannot catch it; restructure so the measurement
spans the window instead. And when adding any liveness witness, construct a case where it must fail
and check that it does -- do not reason about it. Also useful: `./test.sh perf` and
`./test.sh discriminate` are two steps of one CI job, and in the discriminate step's log indented
`FAIL` lines are the EXPECTED mutant failures; only unindented
`FAIL <guard> PASSED against its own defect` lines are real. See
[[project_minio_dockerhub_pull_denied]] for a non-flaky CI break: read which assertion failed before
assuming flakiness.
