#!/usr/bin/env bash
# restore_one_step_backoff.sh <container> <db> [install.sql]
#
# Guard the back-off on restore_incoming_fks' one-step validating re-add (#633, PR verification P1-02). Run by
# CI (`./test.sh perf`), on PostgreSQL 17.
#
# Before PostgreSQL 18 a preserved key whose referencing table is partitioned (here a self-referential key,
# whose referencing table is the managed table itself) cannot be re-added NOT VALID, so restore_incoming_fks
# adds it validating in one step: a scan of the whole managed table under SHARE ROW EXCLUSIVE on it, which
# every writer waits for. An orphan written while the key was suspended fails that scan. maintain calls
# restore_incoming_fks on every tick, and nothing parked the failed key, so every tick scanned the whole table
# again under that lock to fail again on the same orphan. The fix parks it for five minutes
# (dropped_fk.validate_retry_after, the back-off validate_incoming_fks keeps, #265); a call naming the key in
# p_ids retries it at once.
#
# The scan is read off pg_stat_user_tables' tuple counters of the monolith, which flush at transaction end,
# so every sample is taken in a later transaction than the call it measures (each q is its own psql, so its
# own transaction), after a pause for the stats flush. Three calls, each judged by those counters:
#   1. the first re-add scans and fails (LIVENESS: the fixture reached the one-step path and the orphan
#      really blocks it, else a second call reading nothing would prove nothing);
#   2. the next call as maintain makes it, nothing changed since: must read NO row (the defect check);
#   3. a call naming the key in p_ids: must scan again (LIVENESS: the instrument sees a re-attempt, so the
#      zero in 2 is the back-off and not a counter that stopped moving).
#
# The mutation restore_one_step_no_backoff (bench/mutations/mutate.py) removes the back-off; this guard must
# FAIL against it, on the defect check, not on a witness. tests/322 part G asserts the same contract by the
# log, on every PostgreSQL version the core track runs.
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

v=$(q "select current_setting('server_version_num')::int < 180000")
check "GUARD: the server is below PostgreSQL 18, where the re-add is one validating step" "$v" "t"

q "create table public.s (id bigint primary key, pid bigint constraint s_parent_fk references public.s (id), v text);
   insert into public.s select i, nullif(i - 1, 0), 'r' from generate_series(1, 20000) i;" >/dev/null
q "call pgpm.transmute('public.s', 'id', 100000::bigint, p_obtain => 2, p_incoming_fks => 'preserve')" >/dev/null
q "update public.s set pid = 999999 where id = 10" >/dev/null      # the orphan, written while the key is down
mon=$(q "select monolith_oid from pgpm.config where parent_table = 'public.s'::regclass")
fk=$(q "select id from pgpm.dropped_fk where parent_table = 'public.s'::regclass and constraint_name = 's_parent_fk' and restored_at is null")
check "fixture: s is partitioned, its key recorded suspended, one orphan" \
  "$(q "select relkind from pg_class where oid = 'public.s'::regclass"):${fk:+recorded}:$(q "select string_agg(id::text, ',') from public.s where pid is not null and pid not in (select id from public.s)")" \
  "p:recorded:10"
if [ -z "$mon" ] || [ -z "$fk" ]; then exit 1; fi

reads() { q "select seq_tup_read + coalesce(idx_tup_fetch, 0) from pg_stat_user_tables where relid = $mon"; }
fails() { q "select count(*) from pgpm.log where parent_table = 'public.s'::regclass and action = 'fail_restore_incoming_fk' and starts_with(method, 's_parent_fk: ')"; }

sleep 1; r0=$(reads)
q "select pgpm.restore_incoming_fks('public.s')" >/dev/null
sleep 1; r1=$(reads)
check "LIVENESS: the first re-add scanned s and failed on the orphan (rows read > 0, 1 failure)" \
  "$([ $((r1 - r0)) -gt 0 ] && echo scanned || echo "read $((r1 - r0))"):$(fails)" "scanned:1"

q "select pgpm.restore_incoming_fks('public.s')" >/dev/null       # the next tick, as maintain calls it
sleep 1; r2=$(reads)
check "the next call, the orphan unchanged, reads no row of s (no re-scan under the lock)" "$((r2 - r1))" "0"
check "and attempts nothing: still exactly one failure logged" "$(fails)" "1"

q "select pgpm.restore_incoming_fks('public.s', array[$fk]::bigint[])" >/dev/null   # named: retried at once
sleep 1; r3=$(reads)
check "LIVENESS: a call naming the key in p_ids scans again, so the counter sees a re-attempt" \
  "$([ $((r3 - r2)) -gt 0 ] && echo scanned || echo "read $((r3 - r2))"):$(fails)" "scanned:2"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
