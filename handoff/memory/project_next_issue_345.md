---
name: next-issue-345
description: "Issue #345 and its follow-ups, all resolved 2026-09-14: #345 bench scripts MERGED (PR #376 + #379 bug fix); #378 the actual redesign MERGED (PR #380) and closed; #377 CLOSED not-planned, its own premise didn't hold"
metadata:
  type: project
  originSessionId: 232f6d97-aa11-4a2d-98f5-e80e969d8822
  modified: 2026-09-14T14:01:01.359Z
---

Implemented in a fresh session as planned (see the prior entry below, kept for the "why #345"
reasoning). PR #376 (`feat/transmute-regrain-timing-bench`) MERGED 2026-09-14 (merge commit
`a082085`) -- David explicitly asked to merge it with no reviews, in-conversation, after all CI
checks (PG15-18, TimescaleDB, lint) passed; this was a direct instruction in the moment, not an
assumption carried from a past PR ([[feedback_dont_assume_standing_merge_authorization]]).

Results posted as a comment on #345 itself, and two follow-up issues filed per David's go-ahead:
**#377** (transmute: build obtain's forward grid before the attach, seeded from `v_hi_native`
instead of re-scanning via `_frontier_native`) and **#378** (regrain_step: design -- not
implement -- a lower-blast-radius `restore_incoming_fks` for the swap, explicitly constrained by
the no-visible-RI-off invariant). Neither is implemented yet; both are scoped design/measurement
follow-ups. `install.sql` is still untouched by everything in this whole thread of work.

## A real measurement bug turned up while starting #378 (2026-09-14, same day)

When a research fork started digging into #378's design space (asked to plan #377 and #378
together), it independently re-verified #345's own Target 2 contended numbers against a real
container and found the original claim wrong: **PR #376's contended case measured contention
landing on `suspend_fk`**, which runs *before* `DETACH` and takes nothing stronger than
`ACCESS SHARE` on the managed parent -- confirmed directly (a plain SELECT/INSERT against the
parent completed instantly while the probe sat blocked in `suspend_fk`). That never blocks
another session's access to the parent; it only delays how soon the real `ACCESS EXCLUSIVE`
window (`DETACH` through `restore_fk`) begins. The actual risk -- contention landing *inside*
that locked window -- was never tested.

Fixing the bench script (`bench/regrain_swap_timing.sh`) took real iteration, worth remembering
for any future bench work in this repo:
- A reactive fix (poll `pg_locks` for the DETACH lock, race to grab the referencing table's lock
  before `restore_fk` gets there) **lost the race consistently**. Acquiring a fresh `ACCESS
  EXCLUSIVE` table lock measured ~13-40ms in this environment -- bigger than the whole
  `detach`-to-`restore_fk` window at any realistic fixture size, and pre-warming didn't help.
- Widening the fixture (thousands of fine children) DID make the race winnable, but for the
  **wrong reason**: `restore_incoming_fks`'s own in-flight-child gate (a `pg_class` scan) and
  Postgres's own per-partition ATTACH cost both scale badly with partition count, to the point
  the *uncontended* baseline alone exceeded the "was this contended?" pass threshold -- a false
  positive that would have been reported with confidence had it not been caught by cross-checking
  the uncontended baseline at the same fixture size.
- **The actual fix removes the race entirely**: `suspend_incoming_fks` only processes
  `pgpm.dropped_fk` rows with `restored_at IS NOT NULL`; `restore_incoming_fks` only processes
  rows with `restored_at IS NULL`. Deliberately leaving one FK "not yet restored" before the swap
  starts makes a lock pre-acquired on its referencing table *structurally* incapable of contending
  `suspend_fk` and *guaranteed* to contend `restore_fk` -- no timing, no polling.
- A second, related bug: `regrain_step` only calls `restore_incoming_fks` at all when
  `suspend_incoming_fks` suspended something in that *same* call (`if v_fk > 0`). For
  `N_INCOMING_FK=1` this meant the whole contended run silently tested nothing until a liveness
  check caught it. Fixed with a small hidden "trigger" FK, always normally restored, not part of
  the reported count, so suspend always has something to do.

**Corrected numbers (ROWS=2,000,000)**: uncontended `restore_fk` share still grows with FK count
(21%/42%/52% at 1/5/10); contended, `restore_fk` now shows **~99% consistently across every FK
count** (previously ~99% on the wrong bucket, or a false positive). The "go" recommendation for
#378 is unchanged in direction, now on solid ground.

Fixed in **PR #379** (`fix/regrain-swap-timing-contention-window`), MERGED 2026-09-14 (merge
commit `399e1e2`), CI green on all checks first try. Corrected the results comment on #345 and
rewrote #378's issue body + posted a summary comment, both referencing PR #379. Per David's
explicit choice when this was found: "fix bench, re-measure, then correct GitHub" (not: just flag
it and stop, not: correct the text before re-measuring).

**Lesson for future bench/probe work in this repo**: this is exactly the class of defect the
project's own CLAUDE.md warns about (a measurement that passes/reports confidently for the wrong
reason), just found in a *measurement script* rather than a CI guard. The fix pattern that
actually worked -- exploit which processing set a function reads from to get deterministic
isolation, rather than trying to time a race -- is probably the right first instinct next time
before reaching for polling/timing tricks at all.

## #377 CLOSED as not-planned (2026-09-14, same day) -- its own premise didn't hold either

When asked to plan #377's implementation, checked the premise before writing the plan (same
rigor that caught #378's bug) and found it doesn't hold:

- **"Before the attach" reduces nothing.** Phase 3 is one atomic transaction; `ACCESS EXCLUSIVE`
  is acquired at the *rename* (`install.sql:2939`), the first statement in phase 3 -- well before
  the attach (`install.sql:2985`). Since it's all one transaction, the lock is held from the
  rename to commit regardless of internal statement order. Moving `obtain()` from "after
  registration" to "before the attach" keeps it in the exact same already-locked window either
  way. Grid-building also has no legal earlier position: `CREATE TABLE ... PARTITION OF <parent>`
  needs the parent, which doesn't exist until step 5 (`create table ... like <monolith>`), which
  itself needs the monolith's post-rename name -- there is no position for this work that is
  actually outside the lock.
- **Measured where the cost really is** (`ROWS=2000000`, `P_OBTAIN=30`, via a quick
  `pg_stat_statements` check, same mechanism as the bench scripts): `obtain()` totals 11.4ms;
  `_create_partition`'s own work (30x `CREATE TABLE ... PARTITION OF`, inherent DDL) is 10.1ms --
  **89%** of it. `obtain()`'s own loop overhead (the `_frontier_native` redundancy #377 wanted to
  eliminate, plus per-candidate checks) is only ~1.2ms, **11%**. Since obtain is ~92% of phase-3's
  total, even a perfect fix caps the win at ~10% of phase-3 duration -- not worth a new
  grid-construction code path with its own 4-control-kind correctness proof.

Posted the corrected analysis as a comment and **closed #377 as not planned**. David chose this
over re-scoping to the small win or implementing the original (flawed) scope anyway.

**Pattern worth remembering**: two issues filed from the SAME #345 measurement session both had
premises that didn't survive a second look under direct measurement (#378's contention landing on
the wrong bucket; #377's reorder not actually reducing lock duration). Both were caught by
verifying the underlying mechanical claim (what does this lock, when is it acquired, what's the
lock's actual scope) against a real container BEFORE writing an implementation plan, not by
trusting the issue text as filed. Worth doing this same check reflexively for any future
follow-up issue born from a bench/measurement result, even ones already accepted with a "go"
recommendation.

## #378's actual redesign: implemented and MERGED (PR #380, 2026-09-14, same day)

After the correction above, David asked to actually tackle #378 (not just re-measure it). Traced
the lock semantics further before planning (same discipline that caught #377's flawed premise):
`suspend_incoming_fks`'s `DROP CONSTRAINT` takes `ACCESS EXCLUSIVE` on the referencing table and
holds it until the SWAP TRANSACTION COMMITS (locks never release mid-transaction) -- so for any FK
both suspended AND restored within the same swap (the normal case), `restore_fk`'s later `ADD
CONSTRAINT` on that table is just re-acquiring an already-held lock, never a fresh wait. The ONLY
way `restore_fk` can face a genuinely fresh lock acquisition post-DETACH is a FK that was already
sitting "not yet restored" BEFORE the swap started (suspend skips it; restore's own "restore
everything unrestored" sweep still tries it). Confirmed `maintain()`'s own per-tick flow already
commits between `regrain_step` and a SEPARATE outer `restore_incoming_fks` call
(`install.sql:3868-3901`) -- the mechanism the fix leans on already exists.

**Fix**: `regrain_step` snapshots exactly which `pgpm.dropped_fk` rows it is about to suspend
(before suspending), passes that exact set to a newly-scoped `restore_incoming_fks(p_parent,
p_ids bigint[] default null)`. A pre-existing stale FK is left for the next tick, same treatment
the existing `v_fk=0` case already got. PR #380, merged `3c3e871`.

**TDD caught two things worth remembering**: (1) my FIRST draft of the regression test asserted on
raw `pg_constraint` count for an FK referencing a PARTITIONED table -- got 32 rows instead of 1,
spent real time chasing a phantom "environment corruption" bug before realizing PostgreSQL clones
one `pg_constraint` row per partition of the referenced table (`conparentid <> 0` for the clones);
the fix was `and conparentid = 0`, a filter already established elsewhere in this repo's own bench
scripts (`regrain_outgoing_fk_lock.sh`) that I should have reused from memory instead of
rediscovering the hard way. (2) Verified the test actually discriminates by reverting JUST the
`regrain_step` call-site change (keeping the new `restore_incoming_fks` signature) and confirming
exactly the one targeted assertion failed -- this project's CLAUDE.md's core lesson, applied.

**Bench proof**: `bench/regrain_swap_timing.sh`'s existing contended fixture (unchanged) now shows
`restore_fk`'s contended share collapsing to the uncontended baseline at every `N_INCOMING_FK`
(1/5/10: 99.6%->19.5%, 99.4%->44.0%, 99.2%->54.5%, at `ROWS=2000000`) -- posted as the closing
comment on #378, which is now closed.

## #345 itself CLOSED (2026-09-14, same day)

Issue #345 stayed open on GitHub even after both its follow-ups resolved -- commenting isn't
closing. David asked for its status, was told it was functionally complete but still open, and
confirmed closing it. Closed with a summary comment. All three issues from this whole thread
(#345, #377, #378) are now actually closed on GitHub, not just resolved-in-substance.

**Small process note for next time**: check whether an issue is still open before summarizing it
as "done" -- resolving an issue's follow-ups doesn't auto-close the parent, and I said "nothing
outstanding" one turn before realizing #345 itself was still sitting open.

## Not yet done

- Nothing outstanding from #345's own scope; #345/#377/#378 all closed on GitHub as of this
  memory's timestamp. #344 (the original, separate hoist of transmute's setup-replay steps before
  the rename) is still open and unrelated to this session's work -- not touched.

---

_Prior entry (kept for context on why #345 was chosen next, from the scoping session):_

After [[project_next_issue_326]] merged (PR #375), surveyed the remaining open issues (#343, #344,
#345, #346's ranked list, #347, #156, #371) and recommended **#345** as next.

**Why #345 over the alternatives:** it is the one fully spec'd with concrete acceptance criteria, and
it is the blocker for #344 and #347 -- both of which were passed over twice already (see
[[project_next_issue_290]], [[project_next_issue_326]]) specifically for lacking the proof #345
exists to produce. #343 says in its own text it "needs real design thought" (open-ended, not a spec).
#346 is [[project_pgpm_security_hardening_campaign]]'s ranked list -- scope to pick FROM when David
chooses, not a queue to work through unprompted. #156 is a different subsystem (`pgpm_hypertable`),
plausible but never flagged as priority. #371 is unscoped exploratory scoping only, may never be built.

**David explicitly wants this tackled in a NEW Claude Code session, not the one that scoped it** --
same pattern as [[project_next_issue_341]] -> #290 -> #326 -> #345. If a future session is asked to
continue or pick up "the next thing," start with issue #345 directly, this decision already made.
