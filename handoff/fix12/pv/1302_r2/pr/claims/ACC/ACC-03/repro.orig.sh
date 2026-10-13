#!/bin/bash
# The #1232 remedy pgpm_hypertable passes to pgpm._time_unit_contract names, for a timestamp(p) dimension, "widen the
# column's precision (ALTER TABLE <t> ALTER COLUMN <c> TYPE timestamp with time zone), then re-run pgpm.from_hypertable
# (or pgpm.from_hypertable_cutover, the call that follows pgpm.from_hypertable_copy)", and docs/reference.md (the PR's
# hunk) says widening the column first "also works". On the two-phase path it does not: the copy from_hypertable_copy
# made before the refusal still carries timestamptz(0), so the cutover re-run the message names is refused by the shape
# check ("the copy ... no longer has the source's shape"), and the operator has to re-run from_hypertable_copy, which
# the remedy does not say. Fixture: u1, a keyless timestamptz(0) hypertable holding v = 1,2,3, copied, then cut over
# with '500 milliseconds'. Nothing is lost either way (Tier 4: the message changes what the operator types, and it is
# one call short).
set -u
fail=0
q() { $PSQL -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
qe() { $PSQL -X -tA -c "$1" 2>&1; }
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got '$2', want '$3')"; fail=1; fi; }

q "create extension if not exists timescaledb" >/dev/null 2>&1
q "create table public.u1 (ts timestamptz(0) not null, v int)" >/dev/null
q "select create_hypertable('public.u1', 'ts', chunk_time_interval => interval '1 day')" >/dev/null
q "insert into public.u1 select date_trunc('second', now() - g * interval '20 hours'), g from generate_series(1, 3) g" >/dev/null
q "call pgpm.from_hypertable_copy('public.u1', 'ts')" >/dev/null
check "fixture: u1 is a timestamptz(0) hypertable holding 1,2,3 with its copy recorded" \
  "$(q "select (select count(*) from timescaledb_information.hypertables where hypertable_name = 'u1') || '/' || (select string_agg(v::text, ',' order by v) from public.u1) || '/' || (pgpm._from_hypertable_scratch('public.u1', 'hypertable_dest') is not null)::text")" "1/1,2,3/true"

out=$(qe "call pgpm.from_hypertable_cutover('public.u1', 'ts', interval '500 milliseconds', p_predrain => false)")
echo "$out" | grep -m1 ERROR | grep -o 'Give a step.*' | cut -c1-330 | sed 's/^/# remedy: /'
check "LIVENESS: the cutover refused '500 milliseconds' on the timestamptz(0) key, naming the ALTER TABLE and pgpm.from_hypertable_cutover as the re-run" \
  "$(echo "$out" | grep -cF 'precision (ALTER TABLE u1 ALTER COLUMN ts TYPE timestamp with time zone), then re-run pgpm.from_hypertable (or pgpm.from_hypertable_cutover, the call that follows pgpm.from_hypertable_copy)')" "1"
check "LIVENESS: u1 is still a hypertable, its copy still recorded, holding 1,2,3" \
  "$(q "select (select count(*) from timescaledb_information.hypertables where hypertable_name = 'u1') || '/' || (select string_agg(v::text, ',' order by v) from public.u1) || '/' || (pgpm._from_hypertable_scratch('public.u1', 'hypertable_dest') is not null)::text")" "1/1,2,3/true"

# the remedy, typed as the message gives it
alt=$(qe "alter table public.u1 alter column ts type timestamp with time zone")
check "GUARD: the ALTER TABLE the message gives ran on the hypertable" "$(echo "$alt" | grep -c ERROR)" "0"
rerun=$(qe "call pgpm.from_hypertable_cutover('public.u1', 'ts', interval '500 milliseconds', p_obtain => 2)")
echo "$rerun" | grep -m1 ERROR | cut -c1-260 | sed 's/^/# re-run: /'
check "the re-run the remedy names (from_hypertable_cutover after the ALTER) is not refused" "$(echo "$rerun" | grep -c ERROR)" "0"
check "u1 is migrated by the remedy as typed: partitioned, registered, holding 1,2,3" \
  "$(q "select (select relkind::text from pg_class where oid = 'public.u1'::regclass) || '/' || (select count(*) from pgpm.config where parent_table = 'public.u1'::regclass) || '/' || (select string_agg(v::text, ',' order by v) from public.u1)")" "p/1/1,2,3"
exit $fail
