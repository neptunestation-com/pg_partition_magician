#!/usr/bin/env bash
# retirement_mark_needs_dispatch.sh <container> <db> [install.sql | archive_partition_whole.sql]
#
# Run tests/330_retirement_mark_needs_dispatch_test.sql against an ARBITRARY copy of pgpm_core/install.sql or of
# scripts/archive_partition_whole.sql, so that bench/discriminate.sh can show the file catches the defects its
# mutations put back (issue #1259): the
# readers of a retirement mark (pgpm._part_built and through it _part_detached_by_hand, and
# _archive_hold_partition) vouched for pgpm.part.retiring_at by itself, without the record of pgpm's dispatch
# (detach_dispatched_oid) that retire() requires (#705). A mark whose dispatch failed (no pg_cron) on a table the
# operator then detached by hand read as pgpm's own retirement in flight: the next maintain() tick, whose archive
# step runs before retain(), handed the operator's table to the archive strategy and recorded coverage for it, and
# retention dropped it on that coverage once the operator attached it back, its rows archived nowhere. The file is
# the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run against the
# mutant, in the shape of bench/write_block_skips_hand_detached.sh.
#
# The per-PR verification's V-01 is the converse state, guarded by the same file: a mark WITH its record (pgpm's own
# detach landed) on a table archiving was configured for only after the mark was stamped. _archive_hold_partition
# vouched for it, so the step handed the detached table to the strategy, which reading through the parent read none
# of its rows; the range was recorded as covered with 0 rows and retire() dropped the table. No detached table is
# held now: nothing is recorded, retire() keeps it, and the step logs skip_archive with the remedy. Round 3: nor is
# a row with no recorded oid (an upgrade from before #421), whose table the operator detached by hand (part E).
#
# Round 4 (V-01 and V-02 of that round): the hold's ACCESS SHARE does not keep a DETACH PARTITION ... CONCURRENTLY
# from committing its first transaction under it, after which a read through the parent leaves the partition out.
# Both archive paths ask the hold again when the strategy has returned and record nothing on a false answer (parts
# F and G, which drive the detach from a second session through dblink: the call is held at a gate inside the
# strategy until the detach's first transaction is seen committed). V-03: a chunk of 0 rows an older install
# recorded for a table detached by hand no longer opens retire()'s drop gate once the table is attached back: where
# the partition holds rows in such a chunk's range, the coverage is discarded and the partition kept (parts H, I).
#
# The third argument is either module the mutations touch: a copy of the script (recognised by the function it
# defines) is loaded in place of the tree's, with the tree's pgpm_core; anything else is installed as pgpm_core,
# with the tree's script.
#
# SEVEN mutations are required to fail against it (bench/mutations/mutate.py):
#   retirement_mark_vouches_alone            -- pgpm._retirement_vouched answers from the mark alone, without
#                                               _detach_dispatched's record. Part B (the predicates and the
#                                               write-block step).
#   archive_hold_vouches_detached_retirement -- the hold vouches for a detached table carrying pgpm's own
#                                               retirement again (V-01). Parts B and D.
#   retirement_mark_readers_whole            -- #1259's defect whole, both readers. Parts A to D.
#   archive_hold_passes_unanchored           -- the hold passes a row with no recorded oid again. Part E.
#   archive_step_records_without_second_ask  -- pgpm._archive_step records what the strategy returned without
#                                               asking the hold again. Part F.
#   archive_whole_records_without_second_ask -- the script does. Part G.
#   retire_drops_on_contradicted_coverage    -- retire() drops on the ledger's watermark alone, a chunk of 0 rows
#                                               over rows the partition holds included. Parts H and I.
#
# A copy that does not even load is not a catch: that is reported as a `fixture:` failure, which
# bench/discriminate.sh reads as a starved fixture rather than as discrimination.
#
# Runs on the plain core image (pgtap, dblink and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path
# inside the container, TAP_GUARD_INSTALL the core install's and TAP_GUARD_SCRIPT the script's, for a worktree
# mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; FILE="${3:-}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/330_retirement_mark_needs_dispatch_test.sql}"
INSTALL="${TAP_GUARD_INSTALL:-/repo/pgpm_core/install.sql}"
SCRIPT="${TAP_GUARD_SCRIPT:-/repo/scripts/archive_partition_whole.sql}"
LABEL="a retirement mark vouches only with its dispatch record"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

if [ -n "$FILE" ]; then
  if docker exec "$C" grep -q 'function pgpm_archive_next_partition_whole' "$FILE"; then SCRIPT="$FILE"; else INSTALL="$FILE"; fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A copy that will not even load is NOT a catch: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: pgpm_core installed" "$INSTALL"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$SCRIPT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the script under test loaded" "$SCRIPT"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB -S archive_whole_script=$SCRIPT $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
