#!/usr/bin/env bash
# Guard for issue #563: a from_hypertable_cutover whose handoff to transmute REFUSES must not lose what its
# swap already committed.
#
# The cutover commits the irreversible swap (hypertable dropped, incoming foreign keys dropped, the plain
# copy renamed into place with its identity re-added) and only then calls transmute, which can still refuse:
# here, on the monolith name a daily grid derives from a 45-byte table name, which is over PostgreSQL's
# 63-byte limit (#510). Before #563 the dropped keys' definitions and the source sequence's position lived
# only in plpgsql locals until transmute returned, so that refusal left the referencing tables with no key
# and nothing anywhere recording one (no pgpm.dropped_fk row, no log row), and the plain table's identity
# restarting at 1, reissuing ids the table already held (a hypertable's key includes the time column, so
# the duplicates are accepted). The fix records both inside the swap transaction, and transmute carries a
# pgpm.dropped_fk record that names the table it converts onto the new parent, so the operator's remedy
# (re-run transmute once the refusal's cause is fixed) brings the keys back through restore_incoming_fks.
#
# WHY A SHELL HARNESS AND NOT pgTAP. The state under test exists only AFTER the swap's COMMIT, and a pgTAP
# file can only reach a failing committing procedure through throws_*, which runs it inside a function:
# there the first COMMIT dies with 2D000 and rolls the swap back, which is exactly the state a correct
# cutover leaves. The TimescaleDB track cannot take a bare failing CALL either (run_timescale fails a file
# on any ERROR: line), and its image's postgres is not a superuser, so dblink is out. Here the CALL is a
# bare statement in its own psql session, and every observation is a later session's.
#
# WHY IT RUNS ON THE CORE IMAGE. The only TimescaleDB objects the cutover reads are two catalog views
# (timescaledb_information.dimensions, through _from_hypertable_check_dimension, and .jobs), so they are
# stood in for with plain views, and the destination is built exactly as from_hypertable_copy builds it
# (CREATE TABLE ... LIKE, then INSERT ... SELECT). The defect is pgpm's commit ordering, which does not
# depend on TimescaleDB; tests/timescale/db/21_hypertable_swap_order_test.sql covers the same contract's
# success path on a real hypertable.
#
# Fixtures are asymmetric so no two effects can cancel: TWO incoming keys, from two different tables, each
# asserted by name; the source sequence burned AHEAD of max(id) (next 8, max 3), so "seeded past max(id)"
# (4) and "restarted" (1) both read differently from "preserved" (8).
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per half of the fix:
#   hypertable_swap_fk_record_after_handoff -- the swap drops the incoming keys and records them only
#                                              after transmute returns (pre-#563): a refusal loses them
#   hypertable_swap_identity_from_one       -- the swap re-adds identity without the source's position
#                                              (pre-#563): the plain table reissues ids from 1
#   transmute_dropped_fk_parent_not_carried -- transmute leaves a record naming the table it converts on
#                                              the monolith child, so the recovery never restores the keys
#
# Usage: hypertable_swap_order.sh <container> <db> [install.sql]
# The optional file replaces pgpm_hypertable/install.sql when it defines from_hypertable_cutover, and
# pgpm_core/install.sql otherwise, so one guard serves the mutations of both.
# Runs on the plain core image (no TimescaleDB needed; see above).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUT="${3:-}"
CORE=/repo/pgpm_core/install.sql
HT=/repo/pgpm_hypertable/install.sql
if [ -n "$MUT" ]; then
  if docker exec "$C" grep -q 'procedure pgpm.from_hypertable_cutover' "$MUT"; then HT="$MUT"; else CORE="$MUT"; fi
fi
fail=0

q()  { docker exec -i "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() {
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s\n' "$1"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}

REL=hyper_events_with_a_long_descriptive_name1   # 45 bytes
SEQ="pg_get_serial_sequence('app.$REL', 'id')"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$CORE" >/dev/null 2>&1; then
  printf 'FAIL  %-78s %s\n' "pgpm_core installed" "$CORE"; fail=1
fi
if [ "$fail" = 0 ] && ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-78s %s\n' "pgpm_hypertable installed" "$HT"; fail=1
fi
if [ "$fail" != 0 ]; then
  docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit 1
fi

check "fixture: the daily monolith name is over 63 bytes, the swap's own names are not" \
  "$(q "select octet_length('$REL' || '_p2024_01_01_to_2024_01_04') > 63
             and octet_length('$REL' || '_pgpm_delta') <= 63
             and octet_length('$REL' || '_p2024_to_2030') <= 63")" "t"

q "create schema app;
   create table app.$REL (id bigint generated always as identity, ts timestamptz not null, v text,
                          constraint src_pk primary key (id, ts));
   insert into app.$REL (ts, v) values ('2024-01-01 01:00+00', 'a'), ('2024-01-02 01:00+00', 'b'),
                                       ('2024-01-03 01:00+00', 'c');
   select nextval($SEQ) from generate_series(1, 4);
   create table app.ref_a (rid int primary key, h_id bigint, h_ts timestamptz,
                           constraint ref_a_fk foreign key (h_id, h_ts) references app.$REL (id, ts));
   create table app.ref_b (rid int primary key, h_id bigint, h_ts timestamptz,
                           constraint ref_b_fk foreign key (h_id, h_ts) references app.$REL (id, ts));
   insert into app.ref_a values (1, 2, '2024-01-02 01:00+00');
   insert into app.ref_b values (1, 3, '2024-01-03 01:00+00'), (2, 1, '2024-01-01 01:00+00');
   create schema timescaledb_information;
   create view timescaledb_information.dimensions as
     select 'app'::name as hypertable_schema, '$REL'::name as hypertable_name, 1 as dimension_number,
            'ts'::name as column_name, 'timestamptz'::regtype as column_type;
   create view timescaledb_information.jobs as
     select null::name as proc_name, null::name as hypertable_schema, null::name as hypertable_name,
            null::jsonb as config where false;" >/dev/null
# what from_hypertable_copy builds: the plain destination, then the rows
q "create table app.${REL}_pgpm_dest (like app.$REL including defaults including constraints including generated including comments);
   insert into app.${REL}_pgpm_dest (id, ts, v) select id, ts, v from app.$REL order by ts;" >/dev/null

check "LIVENESS: the destination copy holds the three source rows" \
  "$(q "select string_agg(id || ':' || v, ',' order by id) from app.${REL}_pgpm_dest")" "1:a,2:b,3:c"
check "LIVENESS: both incoming keys are live before the cutover" \
  "$(q "select string_agg(conrelid::regclass || ':' || conname, ',' order by conname) from pg_constraint
         where confrelid = 'app.$REL'::regclass and contype = 'f'")" "app.ref_a:ref_a_fk,app.ref_b:ref_b_fk"
check "LIVENESS: the source sequence sits ahead of max(id): next 8, max 3" \
  "$(q "select (select last_value + 1 from $(q "select $SEQ")) || '/' || (select max(id) from app.$REL)")" "8/3"
check "LIVENESS: nothing is recorded before the cutover" \
  "$(q "select (select count(*) from pgpm.dropped_fk) + (select count(*) from pgpm.log)")" "0"

out=$(docker exec -i "$C" psql -U postgres -d "$DB" -q -c \
  "call pgpm.from_hypertable_cutover('app.$REL', 'ts', interval '1 day', p_retain => interval '30 days')" 2>&1)
rc=$?
check "LIVENESS: the cutover failed, on transmute's monolith-name refusal (rc $rc)" \
  "$(echo "$out" | grep -c 'ERROR:  pg_partition_magician: cannot name a partition of')" "1"
check "LIVENESS: the swap committed before the refusal (the copy was renamed into place)" \
  "$(q "select coalesce(to_regclass('app.${REL}_pgpm_dest')::text, 'gone') || '/' || (select relkind::text from pg_class where oid = 'app.$REL'::regclass)")" \
  "gone/r"
check "every source row is reachable under the original name" \
  "$(q "select string_agg(id || ':' || v, ',' order by id) from app.$REL")" "1:a,2:b,3:c"

# THE CONTRACT, part 1: each dropped key is recorded, by name, against the table the swap put in place.
check "each dropped incoming key is recorded in pgpm.dropped_fk against the swapped-in table" \
  "$(q "select string_agg(referencing_table::text || ':' || constraint_name || ':'
                          || (parent_table = 'app.$REL'::regclass) || ':' || (restored_at is null),
                          ',' order by constraint_name) from pgpm.dropped_fk")" \
  "app.ref_a:ref_a_fk:true:true,app.ref_b:ref_b_fk:true:true"
check "the recorded definition names the key's own columns and referenced table" \
  "$(q "select count(*) from pgpm.dropped_fk
         where definition = 'FOREIGN KEY (h_id, h_ts) REFERENCES app.$REL(id, ts)'")" "2"
check "and each drop is logged, action drop_incoming_fk exactly" \
  "$(q "select string_agg(method, ',' order by method) from pgpm.log where action = 'drop_incoming_fk'")" \
  "ref_a_fk,ref_b_fk"

# THE CONTRACT, part 2: the plain table's identity continues from the source's position, not from 1 and
# not from max(id)+1.
newid=$(q "insert into app.$REL (ts, v) values ('2024-01-04 01:00+00', 'd') returning id")
check "the next default id is the source sequence's next value (8)" "$newid" "8"

# THE REMEDY: shorten what the refusal named (a yearly grid here, whose monolith name fits) and re-run
# transmute. The records must follow the table onto the new parent, so the keys come back against it.
out=$(docker exec -i "$C" psql -U postgres -d "$DB" -q -c \
  "call pgpm.transmute('app.$REL', 'ts', interval '1 year', p_paused => true)" 2>&1)
check "LIVENESS: the operator's re-run of transmute succeeds and converts the table" \
  "$(echo "$out" | grep -c 'ERROR:')/$(q "select relkind from pg_class where oid = 'app.$REL'::regclass")" "0/p"
check "the records now name the new partitioned parent, not the monolith child" \
  "$(q "select string_agg(constraint_name || ':' || (parent_table = 'app.$REL'::regclass), ',' order by constraint_name)
         from pgpm.dropped_fk")" "ref_a_fk:true,ref_b_fk:true"
check "restore_incoming_fks re-adds both keys" \
  "$(q "select pgpm.restore_incoming_fks('app.$REL'::regclass)")" "2"
check "both keys are live again, against the parent" \
  "$(q "select string_agg(conrelid::regclass || ':' || conname, ',' order by conname) from pg_constraint
         where confrelid = 'app.$REL'::regclass and contype = 'f' and conparentid = 0")" \
  "app.ref_a:ref_a_fk,app.ref_b:ref_b_fk"
check "and they enforce: an orphan reference is refused" \
  "$(docker exec -i "$C" psql -U postgres -d "$DB" -q -c "insert into app.ref_a values (9, 999, '2024-01-01 01:00+00')" 2>&1 | grep -c 'violates foreign key constraint \"ref_a_fk\"')" "1"
check "LIVENESS: while a valid reference is accepted" \
  "$(q "insert into app.ref_a values (8, 8, '2024-01-04 01:00+00') returning rid")" "8"
check "the sequence position survived the conversion too: the next id is 9" \
  "$(q "insert into app.$REL (ts, v) values ('2024-01-05 01:00+00', 'e') returning id")" "9"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
