#!/bin/bash
# PR #1302's head, as reviewed, does NOT ask the grid's mixed-step rule in pgpm._from_hypertable_check_arguments:
# the block that the PR body says calls pgpm._grid_floor('time', p_interval, anchor, anchor, 'UTC') holds `null;`
# (pgpm_hypertable/install.sql:452-453), so its `exception when others` handler can never fire. The #1268 defect is
# therefore present unchanged: from_hypertable with p_interval '1 mon 1 day' copies and its cutover commits the swap
# (hypertable dropped, incoming key dropped), and only transmute's handoff refuses ('mixed month + duration
# interval unsupported'), leaving a plain unmanaged table; '1 mon -40 days' is refused by the frontier check with a
# remedy that deletes the newest rows, which docs/reference.md now says can never happen ("'1 mon -40 days' ... is
# refused that way, never by the frontier check"). The PR's own test 69 fails its 6 defect checks on this tree.
# Fixture (asymmetric): mx_a (ids 1,2,3; id 2 referenced) through the one-shot driver, mx_b (ids 7,8; id 8
# referenced) copied then cut over, mx_c (ids 1,2,3) for the frontier probe and the control.
set -u
fail=0
q() { $PSQL -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
qe() { $PSQL -X -tA -c "$1" 2>&1; }   # a statement expected to fail: its output, error included

q "create extension if not exists timescaledb" >/dev/null 2>&1
mk() {  # $1 name, $2 ids (sql list), $3 referenced id
  q "create table public.$1 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts))" >/dev/null
  q "select create_hypertable('public.$1', 'ts', chunk_time_interval => interval '1 day')" >/dev/null
  q "insert into public.$1 select g, now() - g * interval '20 hours', g * 10 from unnest(array[$2]) g" >/dev/null
  q "create table public.$1_ref (rid int primary key, h_id bigint, h_ts timestamptz,
       constraint $1_ref_fk foreign key (h_id, h_ts) references public.$1 (id, ts))" >/dev/null
  q "insert into public.$1_ref select 1, id, ts from public.$1 where id = $3" >/dev/null
}
mk mx_a '1,2,3' 2
mk mx_b '7,8' 8
mk mx_c '1,2,3' 2
q "call pgpm.from_hypertable_copy('public.mx_b', 'ts')" >/dev/null

state() {   # hypertable?/incoming key present?/registered?/rows
  q "select (select count(*) from timescaledb_information.hypertables where hypertable_name = '$1')
            || '/' || (select count(*) from pg_constraint where conname = '$1_ref_fk' and conrelid = 'public.$1_ref'::regclass)
            || '/' || (select count(*) from pgpm.config where parent_table = to_regclass('public.$1'))
            || '/' || (select string_agg(id::text, ',' order by id) from public.$1)"
}
check() {   # $1 label, $2 got, $3 want
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got '$2', want '$3')"; fail=1; fi
}

check "LIVENESS: transmute itself refuses '1 mon 1 day' on a plain table (the rule the module must ask first)" \
  "$(q "create table public.plain_mx (ts timestamptz not null, v int); insert into public.plain_mx values (now() - interval '1 hour', 1);" >/dev/null; qe "call pgpm.transmute('public.plain_mx', 'ts', interval '1 mon 1 day')" | grep -c 'mixed month + duration interval unsupported')" "1"
check "LIVENESS: mx_a (1,2,3) and mx_b (7,8) are hypertables, each referenced by its key, unregistered; mx_b's copy recorded" \
  "$(state mx_a) $(state mx_b) $(q "select (pgpm._from_hypertable_scratch('public.mx_b', 'hypertable_dest') is not null)::text")" "1/1/0/1,2,3 1/1/0/7,8 true"

out_a=$(qe "call pgpm.from_hypertable('public.mx_a', 'ts', interval '1 mon 1 day')")
out_b=$(qe "call pgpm.from_hypertable_cutover('public.mx_b', 'ts', interval '1 mon 1 day')")
echo "$out_a" | grep -m1 ERROR | cut -c1-220 | sed 's/^/# a: /'
echo "$out_b" | grep -m1 ERROR | cut -c1-220 | sed 's/^/# b: /'
check "LIVENESS: both calls with p_interval '1 mon 1 day' were refused" \
  "$(echo "$out_a" | grep -c 'ERROR:  pg_partition_magician:')/$(echo "$out_b" | grep -c 'ERROR:  pg_partition_magician:')" "1/1"

check "from_hypertable refused '1 mon 1 day' before its copy and swap: mx_a is still a hypertable, its incoming key in place" \
  "$(state mx_a)" "1/1/0/1,2,3"
check "from_hypertable's refusal is the pre-swap mixed-step one ('refused before anything is changed ... mixed month + duration')" \
  "$(echo "$out_a" | grep -c 'refused before anything is changed.*mixed month + duration interval unsupported')" "1"
check "from_hypertable_cutover refused '1 mon 1 day' before its swap: mx_b is still a hypertable, its incoming key in place" \
  "$(state mx_b)" "1/1/0/7,8"

out_n=$(qe "call pgpm.from_hypertable('public.mx_c', 'ts', interval '1 mon -40 days')")
echo "$out_n" | grep -m1 ERROR | cut -c1-220 | sed 's/^/# c: /'
check "LIVENESS: the '1 mon -40 days' call on mx_c was refused" \
  "$(echo "$out_n" | grep -c 'ERROR:  pg_partition_magician:')" "1"
check "'1 mon -40 days' is refused as a mixed step, never by the frontier check with a delete-the-newest-rows remedy (docs/reference.md)" \
  "$(echo "$out_n" | grep -c 'mixed month + duration interval unsupported')/$(echo "$out_n" | grep -c 'Delete or correct the rows')" "1/0"

q "call pgpm.from_hypertable('public.mx_c', 'ts', interval '1 month', p_paused => true)" >/dev/null 2>&1
check "LIVENESS: the control mx_c migrates with a pure month step: partitioned, registered, its key back, every row" \
  "$(q "select (select relkind::text from pg_class where oid = 'public.mx_c'::regclass)
              || '/' || (select count(*) from pgpm.config where parent_table = 'public.mx_c'::regclass)
              || '/' || (select count(*) from pg_constraint where conname = 'mx_c_ref_fk')
              || '/' || (select string_agg(id::text, ',' order by id) from public.mx_c)")" "p/1/1/1,2,3"
exit $fail
