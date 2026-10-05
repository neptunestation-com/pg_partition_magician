#!/usr/bin/env bash
# Guard from_hypertable_cutover's incoming-key VALIDATE against waiting forever after the handoff (issue #708).
# Run by CI (`./test.sh perf`).
#
# THE DEFECT. After the swap and the handoff to transmute, the cutover re-adds the incoming foreign keys
# the swap dropped (restore_incoming_fks, NOT VALID) and then, after a COMMIT, validates them
# (validate_incoming_fks). The re-add happens to run in transmute's last transaction, under the bound
# transmute set, but the COMMIT ends that, and the VALIDATE ran under the operator's session setting (0 by
# default: wait forever). VALIDATE takes SHARE UPDATE EXCLUSIVE on the referencing table, which a running
# VACUUM, ANALYZE or index build holds, so the operator's cutover waited as long as that lived. The fix
# applies p_lock_timeout to both, and validate_incoming_fks' own per-key handler turns a timeout into a
# fail_validate_incoming_fk row, leaving the key re-added NOT VALID for maintain or a direct call.
#
# HOW THE HOLDER GETS THERE, deterministically. The VALIDATE's window is the instant between the re-add's
# COMMIT and the VALIDATE, so nothing polled from outside can land in it. The lock queue is used instead,
# twice: a lock request that conflicts with a WAITING one queues behind it and is granted the moment that
# one finishes.
#   1. S reads ref_a, so the swap's DROP CONSTRAINT queues for ACCESS EXCLUSIVE on ref_a behind it.
#   2. H1 asks for ROW EXCLUSIVE on ref_a: it queues behind the swap. S is ended; the swap runs and
#      commits; H1 is granted and holds ref_a.
#   3. The re-add of ref_a's key (SHARE ROW EXCLUSIVE) queues behind H1. H2 asks for SHARE UPDATE
#      EXCLUSIVE on ref_a: it queues behind the re-add. H1 is ended; the re-add runs and commits; H2 is
#      granted and holds ref_a.
#   4. The VALIDATE of ref_a's key now queues behind H2, which lives READER_HOLD.
# Every step is a witnessed lock-queue state, each inside a 5 s bound the code under test already had.
#
# WHY IT RUNS ON THE CORE IMAGE. As in bench/hypertable_cutover_lock_timeout.sh: the only TimescaleDB
# objects the cutover reads are two catalog views, stood in for here, and the destination is built exactly
# as from_hypertable_copy builds it. The TimescaleDB track's postgres is not a superuser, so it has no
# dblink and no second session for a pgTAP file to hold a lock with.
#
# ASYMMETRIC. Two incoming keys, from ref_a (held) and ref_b (free): the VALIDATE must fail exactly ref_a's
# and validate exactly ref_b's. One that stopped at the first timeout validates neither.
#
# WHAT IT ASSERTS:
#   LIVENESS  each queue state above, witnessed in pg_locks; the VALIDATE seen queued behind H2.
#   CONTRACT  the cutover returns on its own while H2 is still open.
#   CONTRACT  the timeout is fail_validate_incoming_fk for ref_a_fk exactly, with the lock timeout as its
#             reason; ref_b_fk is validated; both keys are live, ref_a's NOT VALID.
#   LIVENESS  once H2 is gone validate_incoming_fks validates ref_a's key, so the failure was the lock.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   hypertable_handoff_validate_no_lock_timeout -- the set_config before the VALIDATE removed, so it waits
#                                                  for H2's whole life again.
#
# Usage: hypertable_handoff_fk_lock_timeout.sh <container> <db> [install.sql]
# The optional file replaces pgpm_hypertable/install.sql when it defines from_hypertable_cutover, and
# pgpm_core/install.sql otherwise.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUT="${3:-}"
CORE=/repo/pgpm_core/install.sql
HT=/repo/pgpm_hypertable/install.sql
if [ -n "$MUT" ]; then
  if docker exec "$C" grep -q 'procedure pgpm.from_hypertable_cutover' "$MUT"; then HT="$MUT"; else CORE="$MUT"; fi
fi
CUT_CEILING=${CUT_CEILING:-20}
READER_HOLD=${READER_HOLD:-45}
LOG=$(mktemp)
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-84s %s\n' "$1" "$2"
  else printf 'FAIL  %-84s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}
end_app() { # <application_name>: terminate exactly that tagged backend
  docker exec "$C" psql -U postgres -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name = '$1'" >/dev/null 2>&1
}
# waits up to ~$2 tenths of a second for the query $1 to return 1; prints yes or no
await() {
  local _
  for _ in $(seq 1 "$2"); do
    if [ "$(q "$1")" = 1 ]; then echo yes; return; fi
    sleep 0.1
  done
  echo no
}
# 1 when the backend tagged $1 waits (not granted) for lock mode $2 on app.ref_a
queued() {
  echo "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = '$1' and l.relation = 'app.ref_a'::regclass and l.mode = '$2' and not l.granted"
}
# 1 when the backend tagged $1 holds lock mode $2 on app.ref_a
holds() {
  echo "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = '$1' and l.relation = 'app.ref_a'::regclass and l.mode = '$2' and l.granted"
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$CORE" >/dev/null 2>&1; then
  printf 'FAIL  %-84s %s\n' "pgpm_core installed" "$CORE"; exit 1
fi
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-84s %s\n' "pgpm_hypertable installed" "$HT"; exit 1
fi

q "create schema app;
   create table app.hh (id bigint not null, ts timestamptz not null, v text, constraint hh_pk primary key (id, ts));
   insert into app.hh select g, timestamptz '2026-09-01 00:00+00' + g * interval '1 hour', 'r' || g
     from generate_series(1, 48) g;
   create table app.ref_a (rid int primary key, h_id bigint, h_ts timestamptz,
                           constraint ref_a_fk foreign key (h_id, h_ts) references app.hh (id, ts));
   create table app.ref_b (rid int primary key, h_id bigint, h_ts timestamptz,
                           constraint ref_b_fk foreign key (h_id, h_ts) references app.hh (id, ts));
   insert into app.ref_a values (1, 2, timestamptz '2026-09-01 02:00+00'), (2, 7, timestamptz '2026-09-01 07:00+00');
   insert into app.ref_b values (1, 30, timestamptz '2026-09-02 06:00+00');
   create schema timescaledb_information;
   create view timescaledb_information.dimensions as
     select 'app'::name as hypertable_schema, 'hh'::name as hypertable_name, 1 as dimension_number,
            'ts'::name as column_name, 'timestamptz'::regtype as column_type;
   create view timescaledb_information.jobs as
     select null::name as proc_name, null::name as hypertable_schema, null::name as hypertable_name,
            null::jsonb as config where false;
   create table app.hh_pgpm_dest (like app.hh including defaults including constraints including generated including comments);
   insert into app.hh_pgpm_dest select * from app.hh order by ts;
   -- recorded as from_hypertable_copy records the copy it builds (#955): the cutover swaps in nothing else
   select pgpm._scratch_record('app.hh', 'hypertable_dest', 'app.hh_pgpm_dest'::regclass::oid);" >/dev/null
check "LIVENESS: the copy holds the 48 rows, and both incoming keys are live" \
  "$(q "select (select count(*) from app.hh_pgpm_dest) || '/' || (select string_agg(conname, ',' order by conname)
         from pg_constraint where confrelid = 'app.hh'::regclass and contype = 'f')")" "48/ref_a_fk,ref_b_fk"

# 1. S reads ref_a, so the swap's DROP CONSTRAINT queues behind it.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_hhfk_s'" \
  -c "begin; select count(*) from app.ref_a; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
S=$!
check "LIVENESS: S holds ACCESS SHARE on ref_a" "$(await "$(holds pgpm_hhfk_s AccessShareLock)" 50)" "yes"

# The operator's cutover: a bare CALL, no p_lock_timeout, the session's default lock_timeout (0).
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_hhfk_cutover'" \
  -c "call pgpm.from_hypertable_cutover('app.hh', 'ts', interval '1 day')" >"$LOG" 2>&1 &
CUT=$!
check "LIVENESS: the swap's DROP CONSTRAINT is queued for ACCESS EXCLUSIVE on ref_a behind S" \
  "$(await "$(queued pgpm_hhfk_cutover AccessExclusiveLock)" 40)" "yes"

# 2. H1 queues behind the swap, so it is granted ROW EXCLUSIVE the moment the swap commits.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_hhfk_h1'" \
  -c "begin; lock table app.ref_a in row exclusive mode; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
H1=$!
check "LIVENESS: H1 is queued for ROW EXCLUSIVE on ref_a behind the swap" \
  "$(await "$(queued pgpm_hhfk_h1 RowExclusiveLock)" 20)" "yes"
end_app pgpm_hhfk_s
wait "$S" 2>/dev/null

# 3. The re-add of ref_a's key queues behind H1; H2 queues behind the re-add.
check "LIVENESS: the swap committed, H1 holds ref_a, and the re-add is queued behind it" \
  "$(await "select ($(holds pgpm_hhfk_h1 RowExclusiveLock)) * ($(queued pgpm_hhfk_cutover ShareRowExclusiveLock))" 40)" "yes"
check "LIVENESS: the swap has committed: the copy was renamed into the source's place" \
  "$(q "select coalesce(to_regclass('app.hh_pgpm_dest')::text, 'gone')")" "gone"
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "set application_name = 'pgpm_hhfk_h2'" \
  -c "begin; lock table app.ref_a in share update exclusive mode; select pg_sleep($READER_HOLD); commit;" >/dev/null 2>&1 &
H2=$!
check "LIVENESS: H2 is queued for SHARE UPDATE EXCLUSIVE on ref_a behind the re-add" \
  "$(await "$(queued pgpm_hhfk_h2 ShareUpdateExclusiveLock)" 20)" "yes"
end_app pgpm_hhfk_h1
wait "$H1" 2>/dev/null

# 4. The VALIDATE queues behind H2.
check "LIVENESS: the re-add committed, H2 holds ref_a, and the VALIDATE is queued behind it" \
  "$(await "select ($(holds pgpm_hhfk_h2 ShareUpdateExclusiveLock)) * ($(queued pgpm_hhfk_cutover ShareUpdateExclusiveLock))" 40)" "yes"

# THE CONTRACT: the cutover returns while H2 is still open.
t0=$SECONDS
for _ in $(seq 1 $((CUT_CEILING * 5))); do kill -0 "$CUT" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$CUT" 2>/dev/null; then cut="still waiting"; else cut="returned"; fi
check "the cutover returned instead of waiting for H2 (took $((SECONDS - t0)) s after the witness)" "$cut" "returned"
check "LIVENESS: H2 was still open when it did" \
  "$(q "select count(*) from pg_stat_activity where application_name = 'pgpm_hhfk_h2' and state = 'active'")" "1"
check "the cutover itself reported no error, and the table is converted (errors/relkind)" \
  "$(grep -c 'ERROR:' "$LOG")/$(q "select relkind from pg_class where oid = 'app.hh'::regclass")" "0/p"
check "the held key's VALIDATE is fail_validate_incoming_fk exactly, with the lock timeout as its reason" \
  "$(q "select string_agg(action || ':' || method, ',' order by id) from pgpm.log
         where action in ('fail_validate_incoming_fk', 'skip_validate_fk')")" \
  "fail_validate_incoming_fk:ref_a_fk: canceling statement due to lock timeout"
check "the free key is validated, and only it" \
  "$(q "select string_agg(method, ',' order by id) from pgpm.log where action = 'validate_incoming_fk'")" "ref_b_fk"
check "both keys are re-added on their tables, ref_a's NOT VALID (conname:convalidated)" \
  "$(q "select string_agg(conname || ':' || convalidated, ',' order by conname) from pg_constraint
         where confrelid = 'app.hh'::regclass and contype = 'f'")" "ref_a_fk:false,ref_b_fk:true"

# LIVENESS: with H2 gone, the validation the timeout left behind goes through.
end_app pgpm_hhfk_h2
wait "$H2" 2>/dev/null
wait "$CUT" 2>/dev/null
check "LIVENESS: once H2 is gone validate_incoming_fks validates ref_a's key" \
  "$(q "select pgpm.validate_incoming_fks('app.hh')")/$(q "select convalidated from pg_constraint where conname = 'ref_a_fk'")" "1/t"
check "every row survived the migration, by identity" \
  "$(q "select md5(string_agg(id || ':' || v, ',' order by id)) from app.hh")" \
  "$(q "select md5(string_agg(g || ':r' || g, ',' order by g)) from generate_series(1, 48) g")"

rm -f "$LOG"
docker exec "$C" psql -U postgres -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
    where datname = '$DB' and application_name like 'pgpm_hhfk_%'" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
