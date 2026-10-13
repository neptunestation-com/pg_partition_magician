# F11 null results (pass 12, slice S8c: the bench guards)

Budget note: the slice is 289 files. I read 30 units in full (the new guards with logic of their own, the
wrapper template and its variants, discriminate.sh, wrapper_premise_rule.sh, throws_pinned.sh and its sites
guard) and parts of 7 more; for the rest I judged only the `LIVENESS:` relabel lines the diff added (all 237
pure relabels and 149 new LIVENESS lines were extracted and listed) and compared every TAP wrapper's body
mechanically with the shared template. The ledger says which is which. This slice should be split for a
re-run: the ~50 "changed by a few lines" guards (hypertable delta-by-record and copy-lock edits,
adopt_partition.sh parts F and G, lock_trace.sh, the upgrade guards) were NOT read.

## fresh surface

- Every relabel the diff made (`check "LIVENESS: ..."`, `printf 'FAIL ... LIVENESS: ...'`): 237 pure relabels,
  of which ~200 are the shared `the assertions were reached at all` line (a premise by construction) and 37
  others (lock_trace, obtain_backoff_headroom, regrain_outgoing_fk_lock, retire_detach_lock, throws_pinned,
  transmute_claim_squat, transmute_lock, transmute_lock_timeout, untransmute_race, upgrade_from_release,
  upgrade_in_place). Each of the 37 read against its guard's header: every one is a premise the header names
  (probe overlap, work done, origin state, control), none is the check the guard's mutation is caught by.
  upgrade_in_place's "maintain_obtain() still mints" is item 7, a LIVENESS witness by its own header. Held.
- New LIVENESS lines in the new guards (adopt_partition_regrain_lock, restore_one_step_backoff, ledger_backfill,
  retire_pending_detach UPGRADE, over_retired_chunks, ci_runs_lint_jobs, pages_deploy_after_release,
  doc_install_guard_judges_stdin, lint_child_by_oid_inverse, archive_keys_row_read, wrapper_premise_rule,
  liveness_witness_labels, throws_pinned_sites, tests_fail_on_defect): each a premise or a control paired with
  an unprefixed defect check. Checked against each named mutation where the header names which part catches it
  (adopt_partition_regrain_unlocked: two unprefixed checks fail; restore_one_step_no_backoff: the unprefixed
  "reads no row" fails; wrapper_premise_rule's six mutations: each fails an unprefixed check). Held.
- TAP wrapper template: every `were reached at all` wrapper's header test file equals its TEST_FILE default (a
  mechanical check over all of them); body variants (MinIO, demo fixtures, multi-file, --set install) read.
- ci_runs_lint_jobs: CLAIMED F11-02.

## contracts versus documentation

- Labels naming rows over a count: grep over every check label in bench/ naming row ids next to a count(*):
  one hit, CLAIMED F11-01 (retire_pending_detach.sh 177-178).
- doc_install_stops_on_error scan set (living_docs + index.html + install.html) against a grep of every
  .md/.html in the tree for a psql command naming install.sql without ON_ERROR_STOP: only RELEASING.md:134,
  which describes the channel rather than giving a command to type. Held.
- archive_retired_chunk_digest_layer's header claim (only the digest arm can refuse) against tests/archive/db/50:
  90 late rows over the same 90 ids, the throws_like at line 97 follows the adopt and the block. Held.

## time and zones

- No guard in the read set varies TimeZone or DateStyle; the ones that could (regrain_registered_grid_off_unit,
  date_key_anchor_midnight, grid_timezone, datestyle_bounds, crossing_keys_datestyle) are wrappers whose test
  files I did not read. Not probed.

## boundary arithmetic and types

- regrain_swap_lock_budget / tests/315: A is cap + 1 (refused), B exactly cap (prepared and not warned). B's
  "not warned" is a defect check, B's "prepared" is LIVENESS-labelled: a mutant that moved only the prepare
  tick's comparison to `>=` would fail only that witness and read as starved in discriminate (still red in the
  plain suite, so not a wrong-reason pass). Not claimed.
- over_retired_chunks: the parallel-build witness plants min_parallel_table_scan_size = 0 so the boundary is
  reached. Held.

## operator error

- adopt_partition_regrain_lock types the positive remedy (the same call after the holder rolls back) and checks it
  records by oid. Held.

## failure injection

- restore_one_step_backoff injects an orphan; the sibling it did not drive: regrain_step's swap calls
  restore_incoming_fks(p_parent, v_fk_ids) with named ids (install.sql:8619), which by the guard's own header
  bypasses the five-minute back-off. Hypothesis H4.
- retire_pending_detach UPGRADE kills the detach in its virtualxid wait, polled server-side with
  pg_stat_clear_snapshot each iteration. Held.

## Hypotheses (not reproduced)

- H1 (discriminate.sh starved(), the multi-part guards): when a guard prints TAP `not ok` lines AND shell
  `FAIL` lines (ledger_backfill_origin_only_block part 1 + part 2, retire_pending_detach TAP + UPGRADE),
  starved() reads only the TAP lines. A mutant that fails only a LIVENESS witness in the TAP half and a real
  defect check in the shell half is called starved (conservative); the reverse (a defect `not ok` in TAP and
  only witnesses failing in the shell half) is certified correctly. No wrong-reason pass found, but the shell
  half of such a guard is never read by starved() when the TAP half printed anything.
- H2 (throws_pinned.sh line 348): a throws_* site is skipped whenever `--` appears anywhere earlier on its
  line (e.g. `select is(x, 'a--b'); select throws_ok($$ call pgpm.transmute(...) $$, NULL, 'd');`), so an
  unpinned site on such a line is never probed. No such line in tests/ today.
- H3 (reread_under_lock_tap.sh and every pg_prove wrapper): a file that dies mid-plan with no `not ok` line
  prints only `FAIL <file> N ran` (restated, filtered) and no premise, so starved() returns false and the run
  counts as a catch whatever killed it (a mutant breaking a LATER fixture step, not the defect). Deliberate by
  discriminate.sh's header ("an undescribed failure counts"), but it is the #1177 class at N > 0.
- H4 (install.sql:8619, regrain_step's swap): the swap re-adds the keys it dropped by calling
  restore_incoming_fks(p_parent, v_fk_ids), the named-ids path that skips the #633 back-off; on PostgreSQL < 18
  a self-referential preserved key with an orphan would re-scan the whole table under SHARE ROW EXCLUSIVE inside
  every swap attempt. restore_one_step_backoff drives only the maintain path.
- H5 (adopt_partition_regrain_lock.sh): the fix also made adopt_partition refuse a partition pending a
  concurrent detach, or marked pending, "while it waits" for the regrain lock; the guard drives only the lock.
  A partition whose DETACH ... CONCURRENTLY starts while adopt_partition waits on the lock is the untested state.
- H6 (archive_overclaim.sh and 8 other wrappers that load the demo fixture): fixtures/demo.sql is loaded without ON_ERROR_STOP
  and its exit unread; pre-existing, and a broken demo would fail tests/115 rather than pass it.

## Round 2

- Built: H5 widened into F11-03 (Tier 3, shapes 1/3/4). I did not reproduce H5 as written: under READ COMMITTED,
  adopt_partition's re-read after SHARE UPDATE EXCLUSIVE does see a detach that happened while the call waited.
  The re-read runs under the caller's snapshot, though. So in a REPEATABLE READ transaction whose snapshot is
  older than another session's committed DETACH, both reads (install.sql 14014 and 14023) see the partition
  still attached, and pgpm.part records the detached table with attached = true. The READ COMMITTED call on the
  same state refuses, and that refusal is the reproduction's control. This is the same miss the archive hold was
  fixed for (mutation archive_hold_recheck_by_snapshot). I found no row loss: retire() and _archive_step check
  pg_inherits and leave the table alone.
- Tried, not reproduced: H4. regrain_step's swap calls restore_incoming_fks with named ids only for keys it
  dropped while they were LIVE (v_fk > 0). A live, validated key has no orphan to fail on. The suspended
  `preserve` key (the restore back-off fixture) is not one the swap names: the probe showed one
  fail_restore_incoming_fk and no swap-side retry. An orphan under a live key would need replica-role writes;
  I left that unbuilt (budget).
- Not attempted:
  - H1: conservative direction only; no wrong-reason pass to show.
  - H2: no such line exists in tests/, so a claim would need a planted test file. It is cheap, but it ranks
    below the precedence shapes.
  - H3: deliberate per discriminate.sh's own header.
  - H6: pre-existing, not a wrong-reason pass.
  - The mechanical pre-pass: the one weakened assertion it found (a count where the label names rows) was
    already claimed as F11-01 in round 1, so nothing is left unbuilt from it.
