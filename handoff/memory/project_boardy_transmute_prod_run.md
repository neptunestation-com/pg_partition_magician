---
name: project-boardy-transmute-prod-run
description: "Indranil (Boardy) plans to run pgpm.transmute on a large table in Boardy PROD Friday night 2026-09-04, after testing on a traffic-free PROD clone the night of 2026-09-02"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4888f1d5-5db0-4515-90ec-1b6aecca0727
  modified: 2026-09-05T04:27:13.466Z
---

Indranil (Boardy's contact, see [[project-boardy-pilot]]) plans to run `pgpm.transmute` on a
"rather large" table directly in Boardy PROD the night of Friday 2026-09-04. He tested it the
night of Wednesday 2026-09-02 against an **inert clone** of PROD: a copy of the database as of
roughly a week prior (~2026-08-26), with no live traffic.

**Why this matters**: per [[project-boardy-pilot]], pgpm has never run in production anywhere
before Boardy, and this would be the first-ever production `transmute`, on a large table, with
no warranty/SLA. Two review passes (2026-09-01 conversation) already covered issue #339/PR #340
(Parquet enum/array archival, unrelated to this table) — this is a separate, higher-stakes event.

**What I found while reviewing the plan (2026-09-02)**: `pgpm.transmute`'s actual risk profile
(verified against `pgpm_core/install.sql:2739-2762` and `docs/guide.md` "The cutover moves no
rows") is a **write-ceiling window**, not a scaling lock — phase 1 commits an instant
`ADD CONSTRAINT ... NOT VALID`, then phase 2's `VALIDATE CONSTRAINT` scan runs under
`SHARE UPDATE EXCLUSIVE` (blocks nobody) in its own transaction. What actually costs something is
that writes outside `[lo, hi)` are rejected for the whole span between phase 1 and the phase 3
cutover, sized by `p_bound_headroom`. The top-level **README's summary line contradicts this**
("table is locked for the duration of that scan, so size a maintenance window from its row
count") — stale relative to `docs/guide.md` and the code (README last touched 2026-08-20, guide.md
2026-08-25). Fixed 2026-09-02 on branch `docs/fix-transmute-lock-claim` (commit 917b950, pushed,
PR not yet opened).

**`p_bound_headroom` mechanics** (verified against `pgpm_core/install.sql:2650-2734`): headroom is
always N grid steps walked forward from the monolith's own computed `hi`, never measured directly
from `now()`. But what anchors that starting `hi` differs by control kind: for `time` (and
`uuidv7`/`text_time`, via `greatest(decoded max, now())`), the frontier is `now()` at call time
regardless of the table's actual data — so on a stale clone, `hi` is still anchored to the test
session's real wall clock, not the clone's old rows. For plain `id` (bigint/numeric grid), the
frontier is purely `max(control)` in the table with no `now()` involved at all — on a stale clone,
`hi` anchors to the *clone's* stale max id, not to where the live sequence sits on the real run.
This doesn't affect Friday's correctness (the real run recomputes `hi` fresh against live data
when actually invoked), but it does mean a clone-based manual insert test's specific
accepted/rejected values only transfer to Friday numerically if the control kind is time-based;
for `id`-kind, only the enforcement *mechanism* transfers, not the numbers.

**How to apply**: before Friday, verify (a) the live PROD table's current row count/growth rate
against the week-old clone's size, since phase 2's scan duration scales with row count and the
clone under-measures it if the table is still growing; (b) whether `p_bound_headroom` covers
Friday's real write throughput — sizeable via tonight's measured scan duration × Friday's real
write rate ÷ rows-per-grid-step, since the inert clone has zero traffic and cannot exercise the
write-ceiling directly; (c) whether the table has any outgoing FK that is `NOT VALID` (transmute
refuses immediately rather than doing a blocking rescan) or already validated (metadata-only
re-add). If asked to help prep this run, check these three against the actual PROD table rather
than assuming clone results transfer directly.

**Outcome (2026-09-04/05, the actual run)**: succeeded, with real turbulence along the way,
against an 80M-row `prompts."PromptRunLog"` table (`id` = cuid v1 / `text_time`, weekly grid).
Filed two real gaps found while reviewing Indranil's plans: issue #341 (`set_regrain` should
reject a coarser-than-`partition_step` target — silently wedges auto-regrain forever) and issue
#342 (`p_bound_headroom` permanently delays regrain eligibility, undocumented — same root cause as
the headroom mechanics above: headroom permanently widens the monolith's attached bound, and
regrain's frozen check is measured against that same bound). The first
`transmute()` attempt hit `canceling statement due to statement timeout` mid-`VALIDATE CONSTRAINT`
scan (role-level `statement_timeout`, unrelated to `p_lock_timeout` — pgpm never manages
`statement_timeout` itself, confirmed by grep) with 45 minutes still before the intended
write-ceiling boundary; recovered by `pgpm.transmute_abort()` + re-run with a corrected anchor
(pushed 2 hours later) rather than a bare resume, since resuming reuses the recorded bound as-is
and `p_bound_headroom` is silently ignored on resume (`install.sql:2719-2734`). Regrain started
exactly on schedule at the frozen boundary and ran cleanly at 20,000 rows/tick. One more real
finding along the way: `pgpm.schedule()`'s cron job runs as whoever called it (no explicit
`username` to `cron.schedule_in_database`), so a session-scoped `statement_timeout` fix does not
carry over to scheduled ticks — needs `ALTER ROLE ... SET` to persist. Also saw
`skip_write_block`/"lock timeout" log entries during the run: benign, self-healing, and unrelated
to the `statement_timeout` issue — `maintain()` deliberately sets `lock_timeout` to 200ms
(`install.sql:3538`) around per-tick write-block bookkeeping specifically so it never risks
disrupting live traffic, and just retries next tick if it can't get the lock instantly.

**Follow-up filed**: issue #343 (2026-09-05), observability gaps in monitoring
transmute-to-freeze and in-flight regrain — no direct way to know when the monolith freezes,
`regrain_to` missing from `pgpm.status()`, no consolidated regrain-progress view, no ETA,
per-microbatch cost only inferable via `cron.job_run_details`, and `skip_regrain` vs.
`skip_write_block` indistinguishable in `pgpm.log` without reading source. All six gaps are
grounded in things that actually came up manually triangulating this session's run.
