#!/usr/bin/env bash
# Guard regrain against data-coupled work. Run by CI (`./test.sh perf`) and by hand.
#
# THE BAR (issue #263, and the reason #272 existed): a blocking lock may last milliseconds but must never
# last a duration coupled to data size. regrain's swap is the only thing holding ACCESS EXCLUSIVE on the
# parent, so a scan appearing there is the failure that matters.
#
# WHY THIS IS NOT A pgTAP TEST. The assertions read pg_stat_all_tables scan counters, and those are
# accumulated per backend and only flushed at TRANSACTION END: measured, a seq scan of 20000 rows reports
# seq_tup_read growth of 0 when read inside the same transaction and 20000 when read across transactions.
# The sample therefore has to be taken in a later transaction than the work it measures, which this
# harness makes explicit by running every tick below in its own transaction, which is also how maintain
# drives it in production. It lives in bench/ alongside the sibling lock guards, which need a second
# concurrent session observing a first one mid-operation that a single pgTAP file cannot provide.
#
# WHY COUNTERS AND NOT WALL CLOCK. Timing thresholds are flaky on shared CI runners. Scan counters are
# exact and their expected value is zero, so the assertion needs no margin.
#
# Usage: regrain_perf.sh <container> <db> <install.sql>
set -euo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:?install.sql}"
ROWS=100000
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
# a counter read must be its own transaction, after forcing a flush of the previous one
stat() { docker exec "$C" psql -U postgres -d "$DB" -qtA \
           -c "select pg_stat_force_next_flush()" -c "$1" | tail -1; }

check() { # <label> <actual> <limit> <context>
  if [ "$2" -le "$3" ]; then printf 'PASS  %-46s %s <= %s   (%s)\n' "$1" "$2" "$3" "$4"
  else printf 'FAIL  %-46s %s >  %s   (%s)\n' "$1" "$2" "$3" "$4"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.rp (id bigint primary key, payload text);" >/dev/null
q "insert into public.rp select g*2, repeat('x',50) from generate_series(1,$ROWS) g;" >/dev/null
q "call pgpm.transmute('public.rp','id', $((ROWS*2/3+1)));" >/dev/null
# Inside the grid: with no DEFAULT (#288) a write past the forward grid is refused outright, so the
# frontier can only be advanced into a partition that exists. 500000 still puts the monolith's whole
# range below the grid floor, which is what freezes it for regrain.
q "insert into public.rp values (500000,'frontier');" >/dev/null
q "vacuum analyze public.rp;" >/dev/null
CHILD=$(q "select child_name from pgpm.part where parent_table='public.rp'::regclass order by lo::numeric limit 1")
FINE=$(( ROWS / 10 ))

tick() { q "select pgpm.regrain_step('public.rp','$CHILD','$FINE',3000)"; }

for _ in $(seq 1 6); do tick >/dev/null; done          # prepare + copy a few sub-ranges
HALF=$(( ROWS / 2 ))
# a delta over copied rows; its row count is kept, because check 3 needs to know the updates happened
UPD=$(q "with u as (update public.rp set payload='d' where id <= $HALF returning 1) select count(*) from u")
DN=$(q "select pgpm._regrain_delta_count('public.rp')")

# --- 1. a reconcile tick must not scan the whole delta -------------------------------------------------
# This is exactly the #272 regression: an eligibility predicate the planner cannot index turned each tick
# into a seq scan of the entire delta, making the work O(delta^2 / batch).
D0=$(stat "select seq_tup_read from pg_stat_all_tables where relname='rp_pgpm_regrain_delta'")
OUT=$(tick)
D1=$(stat "select seq_tup_read from pg_stat_all_tables where relname='rp_pgpm_regrain_delta'")
check "reconcile tick does not scan the delta" "$(( D1 - D0 ))" "$(( DN / 4 ))" "$OUT, delta=$DN rows"

# --- 2. the swap must not scan the fine children ------------------------------------------------------
# The swap holds ACCESS EXCLUSIVE on the parent via its DETACH. Each ATTACH is metadata-only only because
# every fine child carries a validated bound CHECK; lose that and ATTACH validates by scanning, putting an
# O(rows) pause inside the exclusive window.
n=0
while : ; do
  F0=$(stat "select coalesce(sum(seq_tup_read),0) from pg_stat_all_tables where relname like 'rp\\_p%' and relname <> '$CHILD'")
  OUT=$(tick); n=$(( n + 1 ))
  case "$OUT" in
    swapped:*)
      F1=$(stat "select coalesce(sum(seq_tup_read),0) from pg_stat_all_tables where relname like 'rp\\_p%' and relname <> '$CHILD'")
      check "swap does not scan the fine children" "$(( F1 - F0 ))" 1000 "$OUT, $ROWS rows in the table"
      break;;
  esac
  [ "$n" -gt 400 ] && { echo "FAIL  regrain did not converge"; fail=1; break; }
done

# --- 3. conservation by identity and value, so a fast wrong answer cannot pass -----------------------
# A count cannot tell (#916). The fixture's only captured change is the UPDATE of already-copied rows above,
# so a reconcile that consumes the delta WITHOUT applying it (no scan, which is exactly what checks 1 and 2
# reward) reverts every one of those updates at the swap and keeps the row count. So every row is compared
# with the one it must be, by id: the updated ids read 'd', the rest their original payload, the frontier
# row its own, and no id is missing or extra. The liveness half first: the updates the comparison would
# catch being reverted really happened and were captured, else an all-'x' table would pass it vacuously.
# Mutation regrain_reconcile_discards_delta is that reconcile.
if [ "$UPD" -eq $(( HALF / 2 )) ] && [ "$DN" -gt 0 ]; then
  printf 'PASS  %-46s %s\n' "LIVENESS: captured updates exist to be lost" "$UPD rows updated over copied ranges, delta=$DN rows"
else
  printf 'FAIL  %-46s %s\n' "LIVENESS: captured updates exist to be lost" "$UPD rows updated (expected $(( HALF / 2 ))), delta=$DN rows"
  fail=1
fi
WRONG=$(q "select count(*)
             from (select g*2 as id, case when g*2 <= $HALF then 'd' else repeat('x',50) end as payload
                     from generate_series(1,$ROWS) g
                   union all select 500000, 'frontier') e
             full join public.rp a on a.id = e.id
            where a.id is null or e.id is null or a.payload is distinct from e.payload")
SAMPLE=$(q "select string_agg(id || '=' || left(payload, 1), ' ' order by id)
              from public.rp where id in (2, $HALF, $(( HALF + 2 )), $(( ROWS * 2 )), 500000)")
check "rows conserved, by id and payload" "$WRONG" 0 "rows that differ from the expected set; sample $SAMPLE"

exit "$fail"
