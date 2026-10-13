---
name: next-issue-347
description: "Issue #347 (split obtain() out of maintain()/maintain_all() into its own pg_cron job) implemented, MERGED via PR #382, 2026-09-14"
metadata:
  type: project
  originSessionId: 0f1985ac-835f-43bb-8a2e-703fbd4bcfe0
  modified: 2026-09-14T17:37:25.135Z
---

**STATUS: MERGED, 2026-09-14.** PR #382, branch `feat/split-obtain-into-own-job` (deleted
post-merge). All CI checks green including the perf/discriminate track this PR's own bug lived
in. See [[feedback_pg_lock_tracer_toolbox]] for a debugging-technique note from this session
(deterministic `CALL` + `pg_sleep()` in one uncommitted transaction, then a single `pg_locks`
check, beats polling for lock-timing questions) and [[project_pg_lock_tracer_sdlc_plan]] for the
follow-on plan to bring real eBPF lock tracing into CI, prompted by how long the manual
investigation took.

**What shipped, briefly:** `pgpm.maintain_obtain(p_parent, inout p_status)` +
`pgpm.maintain_obtain_all()` carry `obtain` on their own now; `pgpm.schedule()` takes a second
`p_obtain_every` param and registers a third job, `pgpm_obtain`; `maintain()`/`maintain_all()` no
longer touch obtain at all. Upgrade hazard handled via both a loud doc/CHANGELOG note (fail-loud
option) AND a `warn_obtain_unscheduled` row logged by `maintain_all()` once per sweep when
`pgpm`'s job exists but `pgpm_obtain`'s doesn't (detect+warn option) — both of the issue's
recommended options, not just one.

**The real cost of this session was `bench/maintain_lock.sh`, not the core change.** Obtain's
removal from `maintain()` made the guard's original hazard (obtain's ACCESS EXCLUSIVE leaking into
the regrain copy, all within one `maintain()` call) structurally impossible to reproduce — a
genuinely good side effect of the split, not a regression, but it meant the guard's own mutation
(`maintain_no_commits`) stopped being discriminated and needed a real redesign, not a patch. Ruled
out write-block as a substitute short-lock mechanism definitively: `CREATE TRIGGER` takes
`ShareRowExclusiveLock`, which does not conflict with a plain `SELECT`, so no reader-probe
technique can ever observe it — the codebase's own prior comment claiming ACCESS EXCLUSIVE there
was simply wrong. Landed on a two-table design (a throwaway `mg_ret` table's retain-drop, swept
immediately before `ml`'s regrain in the same `maintain_all()` call) instead. The mutation itself
also had a second latent bug, unrelated to #347: its `BOUNDARY_RE` regex only matched `#279`-tagged
boundary comments and silently missed a `#265`-tagged one (before FK-validate) that commits
unconditionally every tick regardless of incoming FKs — that one boundary alone was enough to
release the test lock early and mask the whole redesign until found.

After merging #344 (see [[project_next_issue_344]]), David said the next pick, #347, should be
tackled in a NEW Claude Code session -- same pattern as every prior pick in this chain
([[project_next_issue_341]] -> #290 -> #326 -> #345 -> #344). If a future session is asked to
continue or "pick up the next thing," start with issue #347 directly; this decision is already
made, no need to re-survey the open-issue list.

**Read the full issue (`gh issue view 347`) at the start of that session; do not work from this
summary alone.** Its own line-number references are against `install.sql` as of `917b950`, and
#344's merge (PR #381, 2026-09-14) added ~150 lines ahead of `maintain()`/`schedule()` in the same
file, so those numbers have drifted twice over. Confirmed in THIS session: `pgpm.maintain` now
starts at install.sql:3775, `maintain_all` at 3962, `schedule` at 4011, `unschedule` at 4033 --
re-locate by content regardless, the issue says so itself.

**The problem, in one sentence:** `maintain_all()` loops over every managed table sequentially in
one session calling `maintain()`, which runs obtain/write-block/archive/retain/regrain/FK-restore
in a fixed order per table -- so a slow archive/retain/regrain for table #3 delays `obtain` for
tables #4..N in the same tick, and unlike every other step, a late `obtain` has a hard consequence
(no DEFAULT partition since #288, so a write past the forward grid is rejected outright, not
queued).

**The fix, in one sentence:** extract `maintain()`'s existing obtain-handling block verbatim into a
new `pgpm.maintain_obtain(p_parent, inout p_status)` + `pgpm.maintain_obtain_all()` pair (mirroring
how `maintain()` already wraps `retain()`/`_archive_step()`/`regrain_step()` as a plain engine
underneath), give `pgpm.schedule()` a second cadence parameter (`p_obtain_every`, default unchanged)
that registers a new `pgpm_obtain` cron job, and strip the obtain block out of `maintain()` --
leaving `maintain_all()` itself structurally untouched, since it just calls a now-smaller
`maintain()`. Do NOT touch `pgpm.obtain()` itself, which stays the pure engine.

**The one landmine already flagged, twice, in the issue itself -- do not miss it:**
`maintain()`'s obtain block currently ends with the boundary `commit;` whose FOLLOWING statement
re-applies `set_config('lock_timeout', '200ms', true)` for the next step (write-block enforcement).
Deleting the whole obtain block deletes that `set_config` too, silently leaving write-block
enforcement running under whatever `lock_timeout` happens to be ambient in the calling session
instead of the deliberate 200ms. The fix must add `perform set_config('lock_timeout', '200ms',
true);` as the FIRST statement of `maintain()`'s remaining body. Also: the `paused` early-return
guards the WHOLE procedure (not just obtain) -- keep it in `maintain()`, only remove the
obtain-specific logic after it.

**The real decision point isn't code, it's the upgrade hazard.** `pgpm.schedule()` is
operator-invoked, never automatic. An existing installation that already called `schedule()` before
upgrading will NOT get the new `pgpm_obtain` job automatically -- if `maintain()` no longer obtains
and nothing else does either, obtain silently stops running until the forward grid runs out and
writes start failing, unwarned. The issue lays out three options (fail loud + document; detect +
warn via a `pgpm.log` row; detect + silently fall back) and recommends the first two together,
explicitly NOT the fallback (recreating the exact hostage problem this issue removes, just hidden).
This needs an explicit, stated decision in the implementation, not silence.

**Test plan is unusually explicit** (read the issue's own text for exact mechanics):
`tests/31_schedule_test.sql`'s `unschedule()` count assertion goes from 2 to 3, plus new assertions
for the `pgpm_obtain` job (existence, command text, its OWN cadence tracking `p_obtain_every`
specifically -- test the two cadence params with DIFFERENT values from each other, to prove they're
independently wired rather than both silently defaulting together). No other pgTAP file should need
to change (`pgpm.log`'s `action` values are unchanged regardless of which procedure produces them);
if one does, something described above leaked further than intended. `docs/guide.md`'s "Run it"
section and `README.md:80-81` both currently describe "one job" and need updating to two.
`./test.sh ci` must pass.

**Non-goals, already settled by the issue itself -- do not "helpfully" expand scope:** do not
further split auto-regrain/retain/archive from each other (no other step has obtain's "or writes
fail" argument for its own job); do not touch `pgpm.obtain()`/`retain()`/`_archive_step()`/
`regrain_step()` themselves; do not touch `pgpm_detach`/`_dispatch_detach` (#268, unrelated,
already necessary for a different reason).
