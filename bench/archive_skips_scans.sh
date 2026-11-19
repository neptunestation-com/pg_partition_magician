#!/usr/bin/env bash
# archive_skips_scans.sh <container> <db> [install.sql]
#
# Guard the cost of status().archive_skips (#1439, PR #1466 round 2, P1-02). Run by CI (`./test.sh perf`).
#
# archive_skips counts a partition's skip_archive rows since that partition's last recorded chunk, and pgpm.log
# keeps every skip a stalled partition ever logged, one per tick. Read with the mark as a subquery per log row,
# one status() call scanned pgpm.archive_ledger once per skip: 20000 skips, 20000 scans, seconds per call on the
# view an operator polls during the very stall it reports. The marks are computed once per call, so the number
# of ledger scans a status() call makes must not grow with the number of skips.
#
# The scans are read off pg_stat_user_tables' seq_scan and idx_scan of pgpm.archive_ledger, which flush at
# transaction end, so every sample is taken in a later transaction than the call it measures (each q is its own
# psql, so its own transaction), after a pause for the stats flush. Two status() calls, one with no skip and one
# with 2000, each judged by those counters:
#   1. with no skip: status() reads the ledger at all (LIVENESS: the instrument sees status()'s reads, so an
#      unchanged count in 2 is the fix and not a counter that never moves);
#   2. with 2000 skips, newer than every chunk: archive_skips reads 2000 (LIVENESS: the skips were really
#      counted), and the call scans the ledger no more often than the call in 1 (the defect check).
#
# The mutation archive_skips_mark_per_log_row (bench/mutations/mutate.py) puts the per-row subquery back; this
# guard must FAIL against it, on the defect check, not on a witness.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtAX -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-72s %s\n' "$1" "$2"
  else printf 'FAIL  %-72s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-72s %s\n' "fixture: the module under test installed" "$INSTALL"
  exit 1
fi

q "create table public.k (id bigint primary key, v text);
   insert into public.k select i, 'r' from generate_series(1, 30) i;" >/dev/null
q "call pgpm.transmute('public.k', 'id', 1000::bigint, p_retain => 17000, p_paused => false)" >/dev/null
q "insert into public.k values (20000, 'frontier')" >/dev/null
child=$(q "select child_name from pgpm.part where parent_table = 'public.k'::regclass and lo = '0'")
oid=$(q "select child_oid from pgpm.part where parent_table = 'public.k'::regclass and lo = '0'")
# fifty recorded chunks of the first partition, then (a later transaction, so a later now()) no skip yet
q "insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, rows_archived, child_oid)
     select 'public.k', (i * 10)::text, (i * 10 + 10)::text, '$child', 0, $oid from generate_series(0, 49) i" >/dev/null
check "fixture: k's first partition has 50 recorded chunks" \
  "$(q "select count(*) from pgpm.archive_ledger where parent_table = 'public.k'::regclass and child_name = '$child'")" "50"

scans() { q "select seq_scan + coalesce(idx_scan, 0) from pg_stat_user_tables where relid = 'pgpm.archive_ledger'::regclass"; }
skips() { q "select archive_skips from pgpm.status() where parent = 'public.k'::regclass"; }

sleep 1; s0=$(scans)
a1=$(skips)
sleep 1; s1=$(scans)
d1=$((s1 - s0))
check "LIVENESS: with no skip, status() reads the ledger (scans > 0) and counts 0" \
  "$([ "$d1" -gt 0 ] && echo reads || echo "scans $d1"):$a1" "reads:0"

q "insert into pgpm.log (parent_table, action, lo, hi, method)
     select 'public.k', 'skip_archive', '0', '1000', 'the bucket refused the upload: ' || g from generate_series(1, 2000) g" >/dev/null
sleep 1; s2=$(scans)
a2=$(skips)
sleep 1; s3=$(scans)
d2=$((s3 - s2))
check "LIVENESS: with 2000 skips newer than every chunk, archive_skips reads 2000" "$a2" "2000"
check "a status() call scans the ledger as often with 2000 skips as with none" \
  "$([ "$d2" -le "$d1" ] && echo same || echo "$d2 scans, against $d1")" "same"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
