#!/usr/bin/env bash
# over_retired_chunks_range_first.sh <container> <db> [install.sql]
#
# Run tests/317_over_retired_chunks_range_first_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# that bench/discriminate.sh can show the file catches the defect its mutation puts back (issue #1163).
# pgpm._over_retired_chunks, called twice by every tick with an archive_fn (_archive_step and retain()), read
# every retired pgpm.archive_ledger row of the parent, with a catalog probe per row, before filtering by range: a
# retired row is never discarded, so the cost of a call that holds nothing grew with the parent's whole archive
# history. The file counts the ledger tuples one call reads (pg_stat_get_xact_* inside one transaction, with the
# instrument's own liveness: a plain read of the retired rows moves it by their number) and pins what the call
# returns by identity, on an id parent and on a time parent whose bounds' text order is not their order. The
# file is the acceptance test; this wrapper exists so the mutation has a guard the discriminate track can run
# against the mutant, in the shape of bench/retain_recall_moved_parent.sh. Each failed assertion is printed as
# its `not ok` line, which is what discriminate.sh's starved() reads, so a mutant that failed only a LIVENESS
# witness is not certified as a catch.
#
# THE PARALLEL REBUILD (PR #1189, V-01). The index that read goes through, archive_ledger_retired_hi_key_idx, is
# over pgpm._native_order_key, whose EXCEPTION block starts a subtransaction, which parallel mode refuses on
# PostgreSQL 15 and 16. Marked parallel safe, it let PostgreSQL build the index in parallel over a ledger past
# min_parallel_table_scan_size, and there the build failed: the upgrade's CREATE INDEX over a long history, every
# REINDEX. The file's part D asserts the declaration and rebuilds the index with the threshold lowered; after it,
# this wrapper rebuilds it once more in its own session at DEBUG1 and requires it to succeed, with its LIVENESS
# witness: under the same settings a btree build over the same ledger on a plain column logs a request for
# parallel workers, so the environment and the ledger's size really do plan a parallel build. On 17 and later
# (the discriminate track runs 17) parallel mode admits the subtransaction, the mutant's rebuild succeeds, and
# the mutation is caught by part D's declaration check alone; the rebuild is the behavioural catch on 15 and 16,
# which the core suite runs part D on.
#
# THE UPGRADE (PR #1189, P1-02). The index's predicate names retired_at, which an install from before #1141 has
# not got until install.sql's upgrade block adds it; created above that block, the index stopped the documented
# upgrade (`--single-transaction`) at 42703 and rolled it back whole. The tests install fresh and never see it, so
# this wrapper installs the released v0.6.0 install.sql (`git show v0.6.0:pgpm_core/install.sql`, the psql
# channel's artifact; the tag is fetched when missing, and a fetch that fails is a FAIL), records a chunk under it,
# re-runs the install under test over it, and requires the run to complete, the index to exist and the chunk to
# have survived by identity. LIVENESS: the origin's ledger really has no retired_at, and holds the chunk.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   over_retired_chunks_reads_all     -- the floor clause on the ledger read is gone, so the call reads every
#                                        retired row of the parent again (the pre-#1163 read); what it returns is
#                                        unchanged, and only the bounded-read assertions fail.
#   native_order_key_parallel_safe    -- pgpm._native_order_key is marked parallel safe again, so the index
#                                        builds in parallel and fails; part D and the rebuild below fail.
#   retired_hi_key_idx_before_column  -- the index is created above the block that adds retired_at, so the
#                                        upgrade from v0.6.0 stops at 42703 and builds nothing.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIGIN_TAG="v0.6.0"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/317_over_retired_chunks_range_first_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a call reads only the retired chunks that can overlap" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a call reads only the retired chunks that can overlap" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

if [ "${ran:-0}" -gt 0 ]; then
  # one session: the settings that make a build of this ledger parallel, then the witness build and the rebuild
  par=(-c "set client_min_messages = debug1" -c "set min_parallel_table_scan_size = 0"
       -c "set max_parallel_maintenance_workers = 2" -c "set maintenance_work_mem = '256MB'")
  wit=$(q -d "$DB" -X -q -v ON_ERROR_STOP=1 "${par[@]}" \
          -c "create index over_retired_witness_idx on pgpm.archive_ledger (parent_table, hi)" \
          -c "drop index pgpm.over_retired_witness_idx" 2>&1)
  if grep -qE 'over_retired_witness_idx.* with request for [1-9][0-9]* parallel workers' <<<"$wit"; then
    printf 'PASS  %-58s %s\n' "LIVENESS: a plain btree build here requests parallel workers" "$(grep -oE 'request for [0-9]+' <<<"$wit")"
  else
    printf 'FAIL  %-58s %s\n' "LIVENESS: a plain btree build here requests parallel workers" "$(grep -m1 -E 'building index|ERROR' <<<"$wit")"
    fail=1
  fi
  out=$(q -d "$DB" -X -q -v ON_ERROR_STOP=1 "${par[@]}" -c "reindex index pgpm.archive_ledger_retired_hi_key_idx" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && ! grep -q 'ERROR' <<<"$out"; then
    printf 'PASS  %-58s %s\n' "archive_ledger_retired_hi_key_idx rebuilds where builds go parallel" "$(grep -m1 -oE 'serially|request for [0-9]+ parallel workers' <<<"$out")"
  else
    printf 'FAIL  %-58s %s\n' "archive_ledger_retired_hi_key_idx rebuilds where builds go parallel" "$(grep -m1 ERROR <<<"$out")"
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1

# ---------------------------------------------------------------- the upgrade from a released v0.6.0
UP="${DB}_up"
uq() { docker exec "$C" psql -U postgres -d "$UP" -X -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
ORIGIN_SQL=$(mktemp)
if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$ORIGIN_TAG^{commit}" >/dev/null 2>&1; then
  git -C "$ROOT" fetch --no-tags --depth=1 origin tag "$ORIGIN_TAG" >/dev/null 2>&1
fi
if ! git -C "$ROOT" show "$ORIGIN_TAG:pgpm_core/install.sql" > "$ORIGIN_SQL" 2>/dev/null || [ ! -s "$ORIGIN_SQL" ]; then
  printf 'FAIL  %-58s %s\n' "the origin artifact was obtained" "git show $ORIGIN_TAG:pgpm_core/install.sql gave nothing"
  rm -f "$ORIGIN_SQL"; exit 1
fi
q -q -c "drop database if exists $UP" >/dev/null 2>&1
q -q -c "create database $UP" >/dev/null 2>&1
if ! docker exec -i "$C" psql -U postgres -d "$UP" -q -v ON_ERROR_STOP=1 -f - < "$ORIGIN_SQL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the origin install completed" "$ORIGIN_TAG"; fail=1
fi
rm -f "$ORIGIN_SQL"
uq "create schema up317; create table up317.a (id bigint primary key, v text not null);
    insert into up317.a select g, 'r' || g from generate_series(1, 90) g" >/dev/null
uq "call pgpm.transmute('up317.a', 'id', 100, p_paused => true)" >/dev/null
child=$(uq "select child_name from pgpm.part where parent_table = 'up317.a'::regclass and lo = '0'")
uq "insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived)
    values ('up317.a', '0', '50', '$child', 49)" >/dev/null
chunk() { uq "select format('%s [%s, %s) %s', child_name, lo, hi, rows_archived) from pgpm.archive_ledger
               where parent_table = 'up317.a'::regclass"; }
check "LIVENESS: the $ORIGIN_TAG ledger has no retired_at column" \
  "$(uq "select count(*) from pg_attribute where attrelid = 'pgpm.archive_ledger'::regclass
           and attname = 'retired_at' and not attisdropped")" "0"
check "LIVENESS: the $ORIGIN_TAG install holds a recorded chunk" "$(chunk)" "${child:-no child} [0, 50) 49"
out=$(docker exec "$C" psql -U postgres -d "$UP" -q -v ON_ERROR_STOP=1 --single-transaction -f "$INSTALL" 2>&1)
rc=$?
check "re-running install.sql over $ORIGIN_TAG completes" "$rc$(grep -m1 -o 'ERROR:.*' <<<"$out" | sed 's/^/ /')" "0"
check "the upgrade built archive_ledger_retired_hi_key_idx" \
  "$(uq "select count(*) from pg_indexes where schemaname = 'pgpm' and indexname = 'archive_ledger_retired_hi_key_idx'")" "1"
check "the recorded chunk survived the upgrade" "$(chunk)" "${child:-no child} [0, 50) 49"
q -q -c "drop database if exists $UP" >/dev/null 2>&1
exit "$fail"
