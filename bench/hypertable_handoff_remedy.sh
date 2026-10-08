#!/usr/bin/env bash
# Guard for issues #1079 and #1089: the remedy docs/reference.md gives for a from_hypertable_cutover whose
# handoff to transmute REFUSES must finish the migration the handoff would have, retention and keys included.
#
# The cutover commits its swap (the hypertable dropped, the copy renamed into place, the incoming keys dropped
# and recorded in pgpm.dropped_fk) and only then calls transmute, which can still refuse: here, because the
# name its carried secondary index needs on the new parent (<index>_pgpm) is taken. The reference then tells
# the operator to fix what the refusal names and finish the handoff themselves. Two things were lost on that
# path:
#   #1079  the retention the handoff passes transmute (p_retain, or left null the source's drop_chunks policy
#          interval) lived only in a plpgsql local. The hypertable and its policy job go with the swap, so the
#          operator's transmute registered the table with retain null and the policy was silently gone. The
#          swap now records it (pgpm.handoff) and transmute, called on that table with p_retain null, takes it.
#   #1089  the reference said the next maintenance tick re-adds the dropped keys, but transmute registers the
#          table paused by default and maintain returns 'paused' before its restore step, so referential
#          integrity stayed off until someone called restore_incoming_fks by hand. The reference now gives the
#          remedy as the three calls the cutover makes after its swap.
#
# THE DOCUMENT IS THE SUBJECT. This guard does not type its own remedy: it reads the SQL block the reference
# gives under "The handoff runs after the swap has committed, and can still refuse" and runs it verbatim (its
# example names the fixture's table, control column and step), so a reference whose remedy stops short fails
# here, measured by the keys and the retention it leaves, not by its wording.
#
# WHY A SHELL HARNESS, AND WHY THE CORE IMAGE. The same reasons as bench/hypertable_swap_order.sh: the state
# under test exists only after the swap's COMMIT, which a bare CALL in its own session reaches and throws_*
# cannot, and the cutover reads only two TimescaleDB catalog views, stood in for here. The Apache TimescaleDB
# the timescale track runs has no retention policies at all, so the drop_chunks interval can only be stood in
# for: timescaledb_information.jobs reads a plain table, and the guard deletes the hypertable's job row after
# the swap as TimescaleDB drops a hypertable's jobs with it. tests/timescale/db/59 drives the same remedy on a
# real hypertable with an explicit p_retain.
#
# ASYMMETRIC FIXTURE. The source holds five rows; two incoming keys from two tables (ref_a referencing two
# rows, ref_b one), each asserted by name and by convalidated; the jobs view carries a 30-day policy for the
# source and a 90-day one for another hypertable, so a retention read by anything but the source's name reads
# 90 days, and a lost one reads null.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   hypertable_handoff_retain_unrecorded       -- the swap records no retention (pre-#1079): the remedy's
#                                                 transmute registers retain null
#   transmute_handoff_retain_unread             -- transmute ignores the record (pre-#1079, the core half)
#   reference_handoff_remedy_without_restore    -- the reference's remedy is transmute alone (pre-#1089): the
#                                                 table is registered paused and no tick re-adds the keys
#
# Usage: hypertable_handoff_remedy.sh <container> <db> [mutant]
# A mutant is the core install.sql, the module's, or docs/reference.md, told apart by content; a /repo/...
# path is mapped to this checkout for the reference, which is read on the host.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; MUT="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE=/repo/pgpm_core/install.sql
HT=/repo/pgpm_hypertable/install.sql
REF="$ROOT/docs/reference.md"
if [ -n "$MUT" ]; then
  if docker exec "$C" grep -q 'procedure pgpm.from_hypertable_cutover' "$MUT" 2>/dev/null; then HT="$MUT"
  elif docker exec "$C" grep -q 'create table if not exists pgpm.config' "$MUT" 2>/dev/null; then CORE="$MUT"
  else REF="${MUT/#\/repo\//$ROOT/}"; fi
fi
fail=0

q()  { docker exec -i "$C" psql -U postgres -d "$DB" -qtA -c "$1" 2>&1; }
check() {
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s\n' "$1"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
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

q "create schema app;
   create table app.events (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
   insert into app.events values (1, now() - interval '5 days', 'a'), (2, now() - interval '4 days', 'b'),
                                 (3, now() - interval '3 days', 'c'), (4, now() - interval '2 days', 'd'),
                                 (5, now() - interval '1 day', 'e');
   create table app.ref_a (rid int primary key, e_id bigint, e_ts timestamptz,
                           constraint ref_a_fk foreign key (e_id, e_ts) references app.events (id, ts));
   create table app.ref_b (rid int primary key, e_id bigint, e_ts timestamptz,
                           constraint ref_b_fk foreign key (e_id, e_ts) references app.events (id, ts));
   insert into app.ref_a select id, id, ts from app.events where id in (2, 4);
   insert into app.ref_b select id, id, ts from app.events where id = 5;
   create index events_v_idx on app.events (v);
   create table app.events_v_idx_pgpm (squatter int);   -- takes the name transmute's carried index needs
   create schema timescaledb_information;
   create view timescaledb_information.dimensions as
     select 'app'::name as hypertable_schema, 'events'::name as hypertable_name, 1 as dimension_number,
            'ts'::name as column_name, 'timestamptz'::regtype as column_type;
   create table app.jobs_state (proc_name name, hypertable_schema name, hypertable_name name, config jsonb);
   insert into app.jobs_state values ('policy_retention', 'app', 'other', '{\"drop_after\": \"90 days\"}'),
                                     ('policy_retention', 'app', 'events', '{\"drop_after\": \"30 days\"}');
   create view timescaledb_information.jobs as select * from app.jobs_state;" >/dev/null
q "create table app.events_pgpm_dest (like app.events including defaults including constraints including generated including comments);
   insert into app.events_pgpm_dest select * from app.events order by ts;
   -- recorded as from_hypertable_copy records the copy it builds (#955): the cutover swaps in nothing else
   select pgpm._scratch_record('app.events', 'hypertable_dest', 'app.events_pgpm_dest'::regclass::oid);" >/dev/null

check "LIVENESS: the source carries a 30-day drop_chunks policy, another hypertable a 90-day one" \
  "$(q "select string_agg(hypertable_name || ':' || (config->>'drop_after')::interval, ',' order by hypertable_name)
         from timescaledb_information.jobs where proc_name = 'policy_retention'")" "events:30 days,other:90 days"
check "LIVENESS: both incoming keys are live on the source" \
  "$(q "select string_agg(conname, ',' order by conname) from pg_constraint
         where confrelid = 'app.events'::regclass and contype = 'f'")" "ref_a_fk,ref_b_fk"

# The operator's cutover, p_retain left null: the source's drop_chunks interval is carried in.
out=$(docker exec -i "$C" psql -U postgres -d "$DB" -q -c \
  "call pgpm.from_hypertable_cutover('app.events', 'ts', interval '1 day')" 2>&1)
rc=$?
check "LIVENESS: the cutover failed, on transmute's taken-index-name refusal (rc $rc)" \
  "$(echo "$out" | grep -c 'ERROR:  pg_partition_magician: cannot transmute .* the name(s) (events_v_idx_pgpm) are already taken')" "1"
check "LIVENESS: the swap committed first (the copy is the table, every row under its name)" \
  "$(q "select (select relkind::text from pg_class where oid = 'app.events'::regclass) || '/'
                || coalesce(to_regclass('app.events_pgpm_dest')::text, 'gone') || '/'
                || (select string_agg(id || v, ',' order by id) from app.events)")" "r/gone/1a,2b,3c,4d,5e"
check "LIVENESS: the swap dropped both incoming keys, and nothing is registered" \
  "$(q "select (select count(*) from pg_constraint where conname in ('ref_a_fk', 'ref_b_fk')) || '/'
                || (select count(*) from pgpm.config)")" "0/0"
# TimescaleDB drops a hypertable's jobs with it: from here on the policy exists nowhere.
q "delete from app.jobs_state where hypertable_name = 'events'" >/dev/null

# THE REMEDY, as the reference gives it: clear what the refusal named, then the reference's SQL block.
q "drop table app.events_v_idx_pgpm" >/dev/null
remedy=$(awk '/^\*\*The handoff runs after the swap has committed, and can still refuse\.\*\*/ { seen = 1; next }
              seen && /^```sql$/ { inblock = 1; next }
              inblock && /^```$/ { exit }
              inblock { print }' "$REF")
check "the reference gives the remedy as a SQL block that calls transmute on the table" \
  "$(echo "$remedy" | grep -c "^call pgpm.transmute('app.events', 'ts', interval '1 day')")" "1"
out=$(echo "$remedy" | docker exec -i "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f - 2>&1)
check "the reference's remedy runs without an error" "$(echo "$out" | grep -c 'ERROR:')" "0"

check "LIVENESS: the remedy converted the table, every row in it, registered paused" \
  "$(q "select (select relkind::text from pg_class where oid = 'app.events'::regclass) || '/'
                || (select string_agg(id || v, ',' order by id) from app.events) || '/'
                || (select paused from pgpm.config where parent_table = 'app.events'::regclass)")" \
  "p/1a,2b,3c,4d,5e/true"
check "the converted table keeps the 30-day retention the cutover carried in (#1079)" \
  "$(q "select coalesce(retain::interval::text, 'null') from pgpm.config where parent_table = 'app.events'::regclass")" \
  "30 days"
check "both incoming keys are back against the new parent, and validated (#1089)" \
  "$(q "select string_agg(conrelid::regclass || ':' || conname || ':' || convalidated, ',' order by conname)
         from pg_constraint where confrelid = 'app.events'::regclass and contype = 'f' and conparentid = 0")" \
  "app.ref_a:ref_a_fk:true,app.ref_b:ref_b_fk:true"
check "and they enforce: an orphan reference is refused" \
  "$(docker exec -i "$C" psql -U postgres -d "$DB" -q -c "insert into app.ref_b values (9, 999, now())" 2>&1 \
     | grep -c 'violates foreign key constraint \"ref_b_fk\"')" "1"
check "LIVENESS: while a valid reference is accepted" \
  "$(q "insert into app.ref_b select 1, id, ts from app.events where id = 1 returning rid")" "1"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
