#!/usr/bin/env bash
# retain_recall_late_detach.sh <container> <db> [install.sql]
#
# Run tests/366_retain_recall_late_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so that
# bench/discriminate.sh can show the file catches the defects its mutations put back (issue #1438): _retain_recall's
# re-attach cleared the retirement marker in the transaction that idled the pgpm_detach job, so a run pg_cron had
# started before that commit, still carrying the armed DETACH ... CONCURRENTLY and queued on the parent behind the
# ATTACH, took the partition out again under no marker; and the idle was a guess, its refusal swallowed. A recall is
# now made only on a job its own attempt confirms idle (or absent), and keeps its mark until pg_cron's run log shows
# that no run can still carry the detach. The file is the acceptance test; this wrapper exists so the mutations have
# a guard the discriminate track can run against the mutant, in the shape of bench/retain_recall_renamed_detached.sh.
#
# NINETEEN mutations are required to fail against it (bench/mutations/mutate.py):
#   recall_reattach_clears_mark        -- the re-attach clears the marker in its own transaction again. Part A.
#   recall_bound_without_proof         -- the mark is cleared with no run above the watermark. Part A's late run.
#   recall_bound_ignores_unfinished    -- an unfinished run of the job does not hold the mark. Part A.
#   recalled_mark_counted_detaching    -- status().retain_detaching counts a recalled mark. Part A.
#   recall_seen_in_own_xact            -- the watermark is read in the recall's own transaction. Part B.
#   retire_slot_held_by_recalled_mark  -- retire() yields its detach slot to a recalled mark. Part C.
#   retire_redispatch_keeps_recalled   -- retire()'s re-dispatch leaves the recall stamps. Part D.
#   retire_drops_recalled_detached     -- retire() drops a table detached under a recalled mark. Part H.
#   recall_unseen_job_absent           -- a caller that sees no job takes it for absent. Parts E1, G.
#   recall_idle_error_swallowed        -- pg_cron's refusal of the idle is swallowed. Parts E2, E3.
#   recall_unschedule_record_ignored   -- pgpm's record of unschedule() is not read. Part G.
#   recall_bound_no_cron_kept          -- with no pg_cron a recalled mark is never cleared. Part F.
#   recall_attached_clear_unbounded    -- an attached recalled mark is cleared without the bound. Part A.
#   recall_unreadable_job_idle         -- an unreadable job is taken for idle, the mark cleared at once. Part A.
#   recall_ledger_not_per_role         -- pgpm's schedule/unschedule record is read as one sequence. Part I.
#   seed_ledger_skips_unlogged_jobs    -- the install does not log the jobs its record lacks. Part L1.
#   seed_ledger_no_placeholder         -- a non-superuser install logs no ?unknown placeholder. Part L2.
#   retire_adopts_recalled_pending     -- retire() adopts a detach pending under a recalled mark. Part J.
#   redispatch_keeps_dispatch_record   -- a failed re-dispatch leaves the old dispatch record. Part K.
#
# Runs on the plain core image (pgtap, dblink and pg_prove; the second sessions are dblink connections ordered by
# the parent's lock, polled server-side, and the test brings its own stand-in for pg_cron's catalog).
# TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree mounted somewhere other
# than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/366_retain_recall_late_detach_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a late detach run is taken back by the next tick" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a late detach run is taken back by the next tick" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
