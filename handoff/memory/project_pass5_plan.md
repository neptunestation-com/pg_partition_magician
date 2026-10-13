---
name: pass5-plan
description: Plan for adversarial review pass 5 (agreed 2026-09-30, to run in a NEW session): rotated lenses, prep items 1-4 DONE 2026-10-01 (PRs #719-#722, main 47a293a), item 5 decided: no release, PIN 47a293a, seed design that the suite cannot catch, fresh-surface targets, budget, and the exact /review-pass command
metadata:
  type: project
---

Pass 5 plan, written 2026-09-30 after pass 4's fix phase closed (record #718 merged, main 30bfc35 = v0.6.0-164).
The user wants to START PASS 5 IN A NEW SESSION; this file is what that session reads first.

**Lenses (6; three of six differ from pass 4, satisfying the "at least half" rule):** fresh surface (always);
identity and names; contracts versus documentation; tests that pass for the wrong reason; upgrade and install
paths (kept: two of pass 4's seven T1s were upgrade-path defects, and the fix phase added three schema objects:
pgpm.regrain_lock, config.monolith_oid, transmute_inflight.control_attnum); concurrency and locks (kept: the
largest T2 source, and both fix-phase interactions were lock-order merges). Dropped from pass 4: time and zones,
boundary arithmetic, operator error, failure injection, resource cliffs. Previous-pass lenses for the record: pass 4's
eight (same as pass 3's).

**PREP STATUS 2026-10-01 02:00Z: items 1 to 4 MERGED, main = 47a293a7d6b7cd611f97f432358ca63140b946c5 (v0.6.0-173).**
Item 1 = PR #721 (tests 109/157/158/162/163 clear the snapshot each turn; the three bench guards were NOT defective,
their per-turn COMMIT ends the snapshot: measured, and said at each loop; discrimination re-proven on PG 17). Item 2 =
PR #719 (classify_claims: scoped loading, invalid_claim class, harness inferred from the install list with
--archive-container/--timescale-container, --only needs no --sealed; verifier.md + SKILL carry the exact command).
Item 3 = PR #720 (land.sh: in-turn enqueue, 5 enqueue requests, skip merged PRs, diff3 rebase, DIRTY fall-out = exit 6
not a flake; keep_both.py any file under diff3 (two-way hunk outside list files refused); landq merged lines on a stop;
gate.sh infers the container, removes a FAILED holder's leftover, GATE_WAIT_TURNS). Item 4 = PR #722 (plant_seeds.py
--suite with an unseeded control per track and pg_prove verdicts, seals suite_caught/suite_noise/suite_baseline;
pass_metrics recall split + read-caught stopping row; docs). #679 CLOSED by #722; #713 commented (still open: discriminate
LIVENESS-only catch, check_living_docs direction, test.sh notes, gate mkdir lottery, archive teardown race, MinIO alias).
Lessons: never run two land.sh at once (a merge under a queued PR made #719 DIRTY: adjacent README rows); the suite
check's first smoke read deliberate ERROR lines as catches, hence the control + pg_prove. Item 5 (cut 0.7.0 first?) is
DECIDED 2026-10-01: NO release before pass 5. THE PIN IS 47a293a7d6b7cd611f97f432358ca63140b946c5 (main after the
four prep PRs, v0.6.0-173). Previous pin (pass 4) was b52a0d9; fresh surface = b52a0d9..47a293a.
Command for the new session: `/review-pass 47a293a7d6b7cd611f97f432358ca63140b946c5 9 fresh-surface, identity-names,
contracts-vs-docs, tests-pass-wrong-reason, upgrade-install, concurrency`, budget "same as pass 3". After planting,
run `scripts/review/plant_seeds.py --suite` (new in #722) and require at least five read-caught seeds before the hunt.

**Prep that must land BEFORE pinning (the pin is main after these):**
1. Fix the pg_stat_activity snapshot class recorded on #713: tests 109/157/158/162/163 and bench maintain_lock.sh,
   regrain_outgoing_fk_lock.sh (the #556 flake), retire_detach_lock.sh poll the view in one transaction without
   pg_stat_clear_snapshot(); fix together, re-prove each guard's discrimination. A known-open defect must not sit in
   the tree the finders review (it would be a "known and open" re-find, not a measurement).
2. Tooling #679: classifier loads only the selected claims and reports a malformed claim.json as invalid_claim;
   container defaulted from the install list (archive claims); verifier brief carries the classifier command.
3. Landing tooling from #713 (needed by the fix phase, not the hunt): land.sh --batch enqueues each PR when ITS head
   is green; retry an enqueue whose GraphQL call errored; write the merged line for a PR that merged before its batch
   stopped; same-spot add/add resolver for any file (6 of 9 hand stops); gate.sh removes a failed run's container.
4. Seed-recall split: plant_seeds.py/pass_metrics.py tag each seed suite_caught (run the pgTAP suite on the seeded
   tree before the hunt) and the record reports recall as suite-caught / read-caught. Pass 4's 9/9 measured "the
   suite was run" (F8 found all nine by running tests, before reading).
5. Decide whether to cut a release first (0.7.0?): main is 0.6.0 + 164; the methodology calls for a full pass after any
   release, so pinning a tag would make pass 5 that pass. User's call.

**Seeds (K=9, sealed, >= 3 novel):** at least five in paths NO pgTAP test exercises (bench-guard-only or unguarded),
so recall measures reading. Spread: 2 identity/names (a search_path-dependent resolution in a helper; an oid anchor
replaced by a rendered name), 2 contracts-vs-docs (a refusal the reference promises quietly widened; a log action
renamed so the runbook's query misses it), 2 tests-pass-wrong-reason (a guard's assertion weakened to cardinality with
its mutation still "caught" through a LIVENESS-only failure, which #713 says discriminate counts as a catch; a throws_ok
pin loosened), 1 upgrade (a backfill that skips rows an older install left null: monolith_oid/control_attnum are fresh),
1 concurrency (a read moved back above a lock in the newly merged #689/#691/#703 untransmute region), 1 fresh-surface
(the #699/#698 conservation merge: drop the untracked-write refusal's ordering). Declare side_effects for any seed
that freezes a tick. Rejected-idea notes from pass 4 still apply (no global fencepost seeds).

**Fresh surface for the dedicated slice:** 67 commits, 101 files, 35 new tests, 37 new guards, 16 of 119 core
functions touched, three schema additions. Read the nine hand-resolved hunks FIRST (#693 reference.md, #684 hypertable
declarations, #688 core install same-spot, #695 guide.md, #696 reference.md table, #704 hypertable same-spot, #703 core
install twice, #699 conservation merge, #691 identity reseed merge), then the two interactions (#699 with #698: count +
fingerprint + untracked-write refusal ordering; #691 with #689: floors in preflight, three values refreshed under the
lock, lattice reseed). Consider TWO fresh-surface slices (core vs hypertable+archive) given the size.

**Budget:** pass 3/4's: 10 finders (8 slices + 2 duplicated on a second model for the split), ~350k tokens / 45 min
each; one verifier (opus, medium) per candidate; <= 5M tokens total. Model split: duplicate the transmute slice (S1, the
largest T3 source) and the fresh-surface slice; opus primary, fable duplicate (pass 4: opus F8 found seeds by running
the suite, fable F10 by reading).

**Command for the new session (after prep lands and the pin is chosen):**
`/review-pass <pinned-sha> 9 fresh-surface, identity-names, contracts-vs-docs, tests-pass-wrong-reason, upgrade-install, concurrency`
then answer the budget question with "same as pass 3". Tell the session this file exists.

**Stopping criteria:** pass 5 is the first pass that could START the two-pass zero-T1 count; T1 was 7, 9, 7 across
passes 2-4 with the surface moving each time. Expect T1 > 0 given 164 commits of new surface; if T1 is 0 with recall
>= 0.8 read-caught, pass 6 decides. See [[pass4-review]] for what pass 4 taught and [[pass3-fix-phase]] for landing shape.
