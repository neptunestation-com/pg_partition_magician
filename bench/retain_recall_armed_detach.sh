#!/usr/bin/env bash
# retain_recall_armed_detach.sh <container> <db> [install.sql]
#
# Run tests/194_retain_recall_armed_detach_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so that bench/discriminate.sh can show the file catches the defects its mutations put back (issues #724, #1438):
# loosening retention (set_retain, or an id frontier moving back) after a referenced partition's concurrent detach
# was dispatched left its rows out of the parent with nothing in pgpm saying so, first because nothing looked at
# the armed command again (#724), then because #724's recall idled the job and re-attached the partition in a
# transaction a pg_cron run already carrying the detach could outlast (#1438), then because the recall cleared a
# dispatched mark on a reading of the job as idle that pg_cron's command cache or row security made wrong (#1451).
# The file is the acceptance test; this
# wrapper exists so the mutations have a guard the discriminate track can run against the mutant, in the shape of
# bench/retire_detached_unreferenced.sh.
#
# TWENTY-EIGHT mutations are required to fail against it (bench/mutations/mutate.py):
#   retain_recall_never             -- nothing settles a retirement retention no longer reaches, the pre-#724
#                                      shape. Parts A, B, C and F.
#   retain_recall_ignores_horizon   -- every retirement is settled, reached or not, so a reached partition's
#                                      landed detach is released rather than dropped. Part D.
#   recall_idles_armed_detach       -- #724's recall of an armed detach: the job idled in the loosening's
#                                      transaction, the mark cleared on the next tick, and a run that had already
#                                      read the command strands the rows. Parts A and F.
#   recall_reattaches_landed_detach -- #1438's pre-fix shape: the landed partition re-attached in the idle's
#                                      transaction, and taken out again by a late run. Part B.
#   recall_release_uncounted        -- the release logged under an action status() does not count. Parts A, C, F.
#   recall_release_leaves_job_armed -- the release leaves the job holding the detach, which undoes the operator's
#                                      ATTACH. Part A.
#   recall_crossing_unlogged        -- a dispatched detach a foreign key refuses for good is left armed with
#                                      nothing logged, its mark holding the detach slot silently. Part G.
#   recall_crossing_takes_back      -- the recall idles that detach itself, which the maintainer ruled out. Part G.
#   recall_default_unlogged         -- a dispatched detach a DEFAULT partition refuses for good is left armed with
#                                      nothing logged. Part I.
#   recall_check_error_counted      -- a reference check that could not run (a lock timeout) is logged and counted
#                                      as a detach that can never land. Part J.
#   untransmute_keeps_detach_check  -- untransmute hands back a released, re-attached monolith still carrying the
#                                      CHECK the concurrent detach left, refusing rows past its old bound. Part H.
#   recall_idle_clears_at_once      -- #1451 path 1: a dispatched mark cleared on the tick that first reads the job
#                                      idle, which a run launched from pg_cron's cache outlasts. Parts E, K, M, N.
#   recall_idle_clock_skipped       -- the minute dropped: the tick after the clock starts clears at once. Part E.
#   recall_idle_clock_starts_at_stamp -- two ticks where three are needed: the first reading starts the clock in the
#                                      idle's own transaction. Parts E and K.
#   recall_idle_clock_in_stamping_xact -- a second tick in the idle's own transaction starts the clock (PR #1459
#                                      round 1, P1-02). Part N.
#   recall_idle_clock_survives_dispatch -- a re-dispatch keeps an earlier dispatch's expired clock. Part M.
#   recall_dispatch_role_unrecorded -- the dispatch records no role, so the role that dispatched its own job's
#                                      detach is refused. Part Q.
#   recall_unseen_job_read_idle     -- #1451 path 2: a role that cannot read the job that holds the detach reads
#                                      it idle. Parts L, O and P.
#   recall_unreadable_job_read_idle -- the same for a role whose read of cron.job raises. Part L.
#   recall_reads_another_roles_job  -- a non-superuser reads its own pgpm_detach job as the administrator's, which
#                                      holds the detach (PR #1459 round 1, V-01). Part O.
#   recall_unrecorded_mark_read     -- a non-superuser reads a mark older than this release as one nothing holds
#                                      (PR #1459 round 1, V-02). Part P.
#   retiring_by_claimed_on_retry    -- retire()'s retry records its role on an older mark, which then reads as this
#                                      release's own, never dispatched. Part P.
#   recall_refused_dispatch_kept    -- a mark this release made whose dispatch was refused is kept for good by a
#                                      non-superuser, though nothing holds it. Part R.
#   retiring_by_kept_on_other_roles_dispatch -- a superuser's re-dispatch keeps the owner's name, so the owner reads
#                                      its own idle job while the administrator's holds the detach. Part S.
#   recall_role_reading_null_unsafe -- the role test is a plain equality, null on a record naming no role, which
#                                      skips the refusal and clears the mark silently. Part S.
#   recall_unreadable_cron_keeps_refused_mark -- a role that cannot read schema cron keeps, counted, a mark whose
#                                      dispatch was refused, which nothing holds (PR #1459 round 2, P1-01). Part T.
#   recall_release_unread_job       -- a tick that cannot read the job holding a landed detach releases it into a job
#                                      still armed (PR #1459 round 2, V-01). Part U.
#   recall_unrecorded_mark_cleared_at_once -- the idle wait skips a mark older than this release, so a superuser's
#                                      tick clears it at once on an idle its own transaction wrote (PR #1459
#                                      round 3, V-01). Part V.
#
# Runs on the plain core image (pgtap and pg_prove; the test brings its own stand-in for pg_cron's
# catalog). TAP_GUARD_TEST_FILE overrides the test file's path inside the container, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/194_retain_recall_armed_detach_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "loosened retention never strands a retirement unrecorded" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "loosened retention never strands a retirement unrecorded" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
