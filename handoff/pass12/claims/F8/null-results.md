# F8 null results and hypotheses, slice S7b (pass 12)

Read first: the six never-read units (regrain_swap_timing.sh, run.sh, run_fh.sh, run_rung.sh, run_rung_fh.sh,
transmute_cutover_timing.sh), then the new and changed guards, then the lints. Budget ran out before the
~130 pg_prove wrappers' headers and wrapped test files, and before most of test.sh and the workflows; the
ledger says which (57 of 199 units read). This slice needs a re-run or a split for the wrappers.

## fresh surface

- throws_pinned.sh / throws_pinned_sites.sh (#1182): scanned every throws_* call in tests/**; every first
  argument is a dollar- or single-quoted literal or a format() (one subselect-of-format in tests/323, which the
  recogniser reads through). The recogniser's self-check and the seven planted spellings hold. Held.
- wrapper_premise_rule.sh with discriminate.sh's starved(): dies_early is refused, a failed defect check
  counts, every reached-at-all line is LIVENESS-prefixed. Held (see H3 for the residue).
- over_retired_chunks_range_first.sh: worried the parallel-rebuild witness ran over an empty ledger (a
  rolled-back test file); tests/317 has no begin/rollback, so the 32,000 rows persist and the witness is real.
  Held.
- restore_one_step_backoff.sh: samples in later transactions after a flush pause; LIVENESS on both sides of
  the defect check. regrain_step's swap calls restore_incoming_fks(p_parent, v_fk_ids), which bypasses the
  back-off, but it only names keys it suspended this call (restored ones), never a parked key. Held.
- pages_deploy_after_release.sh against pages.yml: deploy has no `if`, evaluator modelled, failure liveness
  driven by running publish-dbdev's own build step over a padded copy. Held.
- retire_pending_detach.sh: CLAIMED F8-04 (count under an identity label).
- check_quoted_splices.py (#1179, read by value): CLAIMED F8-01. Probed and held: nested DECLARE blocks,
  `text default ''`, SELECT INTO in all three positions, `if ... then v := quote_ident(...)`.
- check_archive_object_keys.py (#1181): CLAIMED F8-02 (EXECUTE ... USING). Held: a direct `cfg.prefix ||`.

## time and zones

- run_fh.sh's regrain driver shadows now() with a schema ahead of pg_catalog; regrain_step is plpgsql with no
  pinned search_path, so the shadow takes. SKEW_TS is rendered with a literal '+00' after to_char in the
  session's zone (to_char of a timestamptz renders in the session TimeZone, then labels it +00): wrong instant
  when the harness session is not UTC (managed Supabase sessions are UTC, so harmless there). Not built.
- No zone-sensitive guard in the read part of my half varies DateStyle or TimeZone itself; those that do are
  the grid_timezone.sh wrappers, whose test files I did not read.

## boundary arithmetic and types

- obtain_int_ceiling.sh reaches the int4 ceiling exactly (the last expressible cell 2147470000..2147480000) and
  writes by identity. Held.
- regrain_swap_timing.sh's batch = target_step + 1 (documented reason: v_moved < v_batch advances the cursor).
  Held.

## operator error

- run_fh.sh: CLAIMED F8-03 (a named argument the procedure does not have; the documented p_drain_batch).
- run.sh's transmute (bigint overload) and set_regrain calls match the installed signatures. Held.

## failure injection

- transmute_lock_timeout.sh drives one failure (lock_timeout at phase 1); it does not drive a timeout at phase
  3's RENAME, where phase 1 and 2 have already committed the bound (the sibling the header names but does not
  drive). Not built.
- regrain_swap_timing.sh's setup loop runs every regrain_step in ONE DO transaction; with the new snapshot
  wait the swap is outside it, so held.

## contracts versus documentation

- transmute_cutover_order.sh, transmute_lock.sh, regrain_perf.sh, untransmute_fk_validate_lock.sh,
  regrain_fk_drift_swap_scan.sh, obtain_int_ceiling.sh, text_time_collation_proof.sh: each header's promise
  matches its assertions; negatives carry liveness. Held.
- tests_fail_on_defect.sh: judge() refuses a premise-only failure and a file that did not run to its end;
  every planted defect has its own probe liveness. Held.

## Hypotheses (no reproduction built)

- H1 check_quoted_splices.py: `text[]` locals are not TEXT_TYPES, so `v_cols text[] := array_agg(quote_ident(..))`
  later spliced with array_to_string(...) under %s is never judged. Also FOREACH targets (same gap as F8-01).
- H2 check_quoted_splices.py bodies() splits on bare `$$` only; a function body under any other tag
  (`$fn$`) is never read, and the MIN_QUOTED floor does not notice one function going dark. lint.yml's sql-syntax
  job (and test.sh's copy) checks `$$` balance in pgpm_core/install.sql only, though the docstring relies on it for
  all three files.
- H3 discriminate.sh starved() / every pg_prove wrapper: a mutant whose test file passes its LIVENESS premises and
  then RAISES at a later fixture statement prints only `FAIL <label> N ran` (N > 0, a restated verdict, set aside),
  so descs is empty and starved() returns false: discriminate counts it as a catch although no defect check
  failed. Build: a wrapper whose test file's premise passes, then a setup statement the mutant breaks.
- H4 upgrade_in_place.sh assertion 7 ("maintain_obtain still mints partitions after the upgrade") is a
  post-condition of the upgrade printed with the LIVENESS: prefix, so a mutant that only breaks obtain after an
  upgrade would be refused by discriminate as a starved fixture rather than certified (the guard itself still
  fails, so the perf track is red; only the certification is wrong).
- H5 run.sh's CONSERVATION GATE compares count(id < B) before and after the regrain: cardinality, not identity. The
  workload (bench/sql/20_workload.sql, not read) would have to leave history rows untouched for the count to be
  meaningful; a regrain that loses one row and duplicates another passes it.
- H6 run_rung_fh.sh's reset drops schemas pgpm/bench/pgfr but no hypertable-module residue outside them (e.g. a
  leftover <rel>_pgpm_dest in another schema); not checked.
- H7 transmute_lock.sh's probe takes the first ShareUpdateExclusiveLock on any relation named tl as the
  validation scan; an autovacuum SUE lock would satisfy it and the reader check would then run against nothing
  (unlikely after the explicit vacuum analyze; not built).
- H8 grid_timezone.sh wrappers use GRID_TZ_TEST_FILE="${GRID_TZ_TEST_FILE:-...}": a GRID_TZ_TEST_FILE left in
  the caller's environment makes every such wrapper run that one file instead of its own.
- H9 test.sh run_perf lists bench/day_label_utc.sh twice (pgpm_perf36 and pgpm_perf37); not my unit, noted.
- H10 archive.yml, observe.yml, locktrace.yml and lockview.yml feed none of the three required summaries (Test,
  Lint, Perf); CLAUDE.md says the merge queue "merges the group only if it is green", which holds only for
  required checks unless the ruleset names these jobs too (the ruleset is not in the tree).
- H11 check_archive_child_by_oid.py: a by-name lookup through a text-taking catalog function
  (has_table_privilege(text, ...), pg_relation_size of a text cast) is outside its rule 1's name columns and casts,
  and is not in its documented blind spots. Not built.

## Round 2

None of my hypotheses has one of the six long-surviving catalog/lock shapes; the labelling and verdict ones were
built first, as repro.sh files that run the guard's or the lint's own reading from $TREE.

- Built: H5 -> F8-05 (run.sh's conservation gate is a count; accepts row 5 lost and a stranger 50 invented, Tier 5).
- Built: H4 -> F8-06 (upgrade_in_place.sh assertion 7, a post-upgrade property, prints LIVENESS: and starved()
  reads a mutant that only breaks post-upgrade obtain as a starved fixture, Tier 5).
- Built: H3 -> F8-07 (a wrapper whose file passes its premise then raises prints only `FAIL <label> 1 ran`;
  starved() reads it as a catch; control: a raise before the first assertion is read as starved, Tier 5).
- Built: H2 -> F8-08 (check_quoted_splices.py reads only bare-$$ bodies; the same unmarked quoted local under
  $fn$ passes, under $$ is refused, Tier 5). The sql-syntax half of H2 (only core's $$ balance checked) not built.
- Not attempted: H1 (text[] locals: TEXT_TYPES is the docstring's declared scope, so a weak claim); H6 (needs a
  green at-scale instance); H7 (autovacuum race, not drivable on demand in budget); H8 (an environment
  override, operator-only); H9 (not my unit); H10 (the ruleset is not in the tree, so not reproducible from it);
  H11 (needs the archive lint's rule code read, which is the slice being re-run).
