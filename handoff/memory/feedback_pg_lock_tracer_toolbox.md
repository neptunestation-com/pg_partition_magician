---
name: pg-lock-tracer-toolbox
description: eBPF-based pg-lock-tracer suggested as a toolbox option for debugging Postgres lock semantics
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c67f064d-dcf1-4b6b-a5c0-66535171dcf9
  modified: 2026-09-14T16:37:32.057Z
---

When debugging confusing PostgreSQL lock-acquisition/release behavior (e.g. "why did this lock
disappear before I expected"), consider `pg-lock-tracer`
(https://github.com/jnidzwetzki/pg-lock-tracer, described at
https://jnidzwetzki.github.io/2023/01/11/trace-postgresql-locks-with-pg-lock-tracer.html) -- an
eBPF tool that traces Postgres lock acquire/release via USDT probes, giving a continuous event
trace instead of `pg_locks` polling snapshots.

**Why:** David suggested this mid-session while I was debugging why a mutation-testing bench
guard ([[project_next_issue_347]]) wasn't discriminating -- `pg_locks` polling at ~120ms
intervals was missing genuinely-brief lock windows, which looked at first like a real behavioral
difference but was actually a visibility gap for one failure mode (though the deciding case that
session turned out to be root-caused by a different technique: a deterministic
`CALL ...; PERFORM pg_sleep(N);` inside one uncommitted transaction, then a single `pg_locks`
check -- no polling needed, since the sleep guarantees the window).

**How to apply:** Reach for `pg-lock-tracer` when a deterministic single-window check (background
a CALL immediately followed by `pg_sleep()` in the same uncommitted transaction/DO block, then one
`pg_locks` read) isn't practical -- e.g. when the lock's holder can't be paused with an injected
sleep, when multiple sessions/timings interact, or when polling keeps missing a window and it's
unclear whether that's a real release or a sampling gap. For a single procedure call whose
transaction boundary you control, the deterministic sleep-and-check technique is simpler and
sufficient; don't reach for eBPF tooling until that's not an option.
