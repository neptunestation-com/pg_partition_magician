#!/usr/bin/env bash
# Guard from_hypertable_cutover against queueing forever behind a long reader (issue #665).
# Run by CI (`./test.sh perf`).
#
# THE DEFECT. The cutover takes `lock table <source> in access exclusive mode` for its swap. With no
# lock_timeout (the session default, 0) the request waits for as long as any reader of the hypertable
# lives, and a PENDING ACCESS EXCLUSIVE queues every later lock request behind it: every new read and
# write of the production table waited for one unrelated query. The fix gives the cutover p_lock_timeout
# (default '5s', transmute's own default, #309) and applies it to the swap transaction, so the cutover
# gives up, rolls the swap back whole, and can be re-run.
#
# WHY A SHELL HARNESS. It needs a reader holding the source while the cutover waits and a third session
# timing a plain read behind them; pgTAP gives one session, and the TimescaleDB track has no superuser
# for dblink. tests/timescale/db/24 pins the parameter's contract (refused up front, accepted when good)
# on a real hypertable.
#
# WHY IT RUNS ON THE CORE IMAGE. As in bench/hypertable_swap_order.sh: the only TimescaleDB objects the
# cutover reads are two catalog views, stood in for here, and the destination is built exactly as
# from_hypertable_copy builds it. The defect is the cutover's unbounded LOCK TABLE, which does not depend
# on TimescaleDB: the lock queue is PostgreSQL's.
#
# WHAT IT ASSERTS, each paired with the witness that makes it mean something:
#   LIVENESS  the reader holds ACCESS SHARE on the source; the cutover is seen QUEUED for ACCESS EXCLUSIVE
#             behind it (so the wait the contract bounds really happened).
#   CONTRACT  a plain one-row read of the source completes under a ceiling far below the reader's life.
#   CONTRACT  the cutover gave up with lock_not_available while the reader was still open.
#   CONTRACT  it gave up whole: the same source relation, still a plain table with its rows, the copy
#             still there, no pre-built index left on it, nothing registered with pgpm.
#   LIVENESS  once the reader is gone the identical call completes the migration.
#
# The call is the operator's bare CALL with no p_lock_timeout, so the DEFAULT is what is guarded.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   hypertable_cutover_no_lock_timeout -- the swap's set_config removed (p_lock_timeout kept in the
#                                         signature), so the LOCK TABLE waits forever again.
#
# Usage: hypertable_cutover_lock_timeout.sh <container> <db> [install.sql]
# The optional file replaces pgpm_hypertable/install.sql when it defines from_hypertable_cutover, and
# pgpm_core/install.sql otherwise.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUT="${3:-}"
CORE=/repo/pgpm_core/install.sql
HT=/repo/pgpm_hypertable/install.sql
if [ -n "$MUT" ]; then
  if docker exec "$C" grep -q 'procedure pgpm.from_hypertable_cutover' "$MUT"; then HT="$MUT"; else CORE="$MUT"; fi
fi
READ_CEILING=${READ_CEILING:-12}
READER_HOLD=${READER_HOLD:-40}
LOG=$(mktemp)
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$2"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}
end_reader() {
  docker exec "$C" psql -U postgres -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name = 'pgpm_hclt_reader'" >/dev/null 2>&1
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$CORE" >/dev/null 2>&1; then
  printf 'FAIL  %-78s %s\n' "pgpm_core installed" "$CORE"; exit 1
fi
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-78s %s\n' "pgpm_hypertable installed" "$HT"; exit 1
fi

q "create schema app;
   create table app.hclt (id bigint not null, ts timestamptz not null, v text, constraint hclt_pk primary key (id, ts));
   create index hclt_v_idx on app.hclt (v);
   insert into app.hclt select g, timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', 'r' || g
     from generate_series(1, 72) g;
   create schema timescaledb_information;
   create view timescaledb_information.dimensions as
     select 'app'::name as hypertable_schema, 'hclt'::name as hypertable_name, 1 as dimension_number,
            'ts'::name as column_name, 'timestamptz'::regtype as column_type;
   create view timescaledb_information.jobs as
     select null::name as proc_name, null::name as hypertable_schema, null::name as hypertable_name,
            null::jsonb as config where false;
   create table app.hclt_pgpm_dest (like app.hclt including defaults including constraints including generated including comments);
   insert into app.hclt_pgpm_dest select * from app.hclt order by ts;" >/dev/null
SRC_OID=$(q "select 'app.hclt'::regclass::oid")
check "LIVENESS: the destination copy holds the 72 source rows" "$(q "select count(*) from app.hclt_pgpm_dest")" "72"

# The long reader, tagged so the teardown terminates exactly this backend.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_hclt_reader'" \
  -c "begin; select count(*) from app.hclt; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
READER=$!
held=no
for _ in $(seq 1 50); do
  if [ "$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_hclt_reader' and l.relation = 'app.hclt'::regclass
                and l.mode = 'AccessShareLock' and l.granted")" = 1 ]; then held=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the reader holds ACCESS SHARE on the source" "$held" "yes"

# The operator's cutover: a bare CALL, no p_lock_timeout, the session's default lock_timeout (0).
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_hclt_cutover'" \
  -c "call pgpm.from_hypertable_cutover('app.hclt', 'ts', interval '1 day')" >"$LOG" 2>&1 &
CUT=$!
queued=no
for _ in $(seq 1 40); do
  if [ "$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
              where a.application_name = 'pgpm_hclt_cutover' and l.relation = 'app.hclt'::regclass
                and l.mode = 'AccessExclusiveLock' and not l.granted")" = 1 ]; then queued=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the cutover is queued for ACCESS EXCLUSIVE on the source behind the reader" "$queued" "yes"

# THE CONTRACT: a plain one-row read of the production table, timed.
t0=$SECONDS
out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set statement_timeout = '${READ_CEILING}s'" \
  -c "select v from app.hclt where id = 3" 2>&1)
check "a plain read of the source is not held up behind the cutover (took $((SECONDS - t0)) s)" "$out" "r3"

for _ in $(seq 1 $((READ_CEILING * 5))); do kill -0 "$CUT" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$CUT" 2>/dev/null; then cut="still waiting"
else cut=$(grep -c 'canceling statement due to lock timeout' "$LOG"); fi
check "the cutover gave up on the lock (lock_not_available) instead of waiting" "$cut" "1"
check "LIVENESS: the reader was still open when it did" \
  "$(q "select count(*) from pg_stat_activity where application_name = 'pgpm_hclt_reader' and state = 'active'")" "1"
check "it gave up whole: same source oid, a plain table, all its rows" \
  "$(q "select (to_regclass('app.hclt')::oid = $SRC_OID) || '/' || (select relkind::text from pg_class where oid = $SRC_OID)
            || '/' || (select count(*) from app.hclt)")" "true/r/72"
check "the copy is still there, with no pre-built index left on it" \
  "$(q "select (select count(*) from app.hclt_pgpm_dest) || '/'
            || (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
                 where i.indrelid = 'app.hclt_pgpm_dest'::regclass and c.relname like '%\_pgpm\_new')")" "72/0"
check "nothing was registered with pgpm" "$(q "select count(*) from pgpm.config")" "0"

# LIVENESS: with the reader gone, the identical call completes, so the refusal above was the lock.
end_reader
wait "$READER" 2>/dev/null
wait "$CUT" 2>/dev/null
out=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -c "call pgpm.from_hypertable_cutover('app.hclt', 'ts', interval '1 day')" 2>&1)
check "LIVENESS: once the reader is gone the same call migrates the table" \
  "$(echo "$out" | grep -c 'ERROR:')/$(q "select relkind from pg_class where oid = 'app.hclt'::regclass")" "0/p"
check "every row is there after the migration, by identity (md5 of id:v in id order)" \
  "$(q "select md5(string_agg(id || ':' || v, ',' order by id)) from app.hclt")" \
  "$(q "select md5(string_agg(g || ':r' || g, ',' order by g)) from generate_series(1, 72) g")"

rm -f "$LOG"
docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
