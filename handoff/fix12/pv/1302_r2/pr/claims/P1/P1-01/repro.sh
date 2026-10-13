#!/bin/bash
# PR #1302 says pgpm._from_hypertable_check_arguments now asks the grid's mixed month + duration step rule by
# calling pgpm._grid_floor itself, so from_hypertable refuses '1 mon 1 day' before its copy and
# from_hypertable_cutover before its pre-drain and its swap (docs/reference.md: "refused before the copy and
# the swap ... never by the frontier check"). On this tree the body of that check holds `begin null; exception
# ... end;` where the _grid_floor call should be, so the rule is never asked: both entry points copy, the
# cutover's swap commits (hypertable dropped, incoming key dropped), and only the handoff refuses, leaving a
# plain table pgpm does not manage; and '1 mon -40 days' meets the frontier check first, whose remedy deletes
# the newest rows.
# Fixture (asymmetric): mx_a (ids 1,2,3; id 2 referenced by mx_a_ref) through the one-shot driver, mx_b (ids
# 7,8; id 8 referenced by mx_b_ref) copied then cut over, mx_c (ids 1,2,3) for the '1 mon -40 days' probe and
# as the control that migrates with a pure month step.
set -u
fail=0
q()  { $PSQL -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
qe() { $PSQL -X -tA -c "$1" 2>&1; }   # a statement expected to fail: its output, error included
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got '$2', want '$3')"; fail=1; fi; }

for t in a b c; do
  q "create table public.mx_$t (id bigint not null, ts timestamptz not null, v int, primary key (id, ts))" >/dev/null
  q "select create_hypertable('public.mx_$t', 'ts', chunk_time_interval => interval '1 day')" >/dev/null
  q "create table public.mx_${t}_ref (rid int primary key, h_id bigint, h_ts timestamptz,
       constraint mx_${t}_ref_fk foreign key (h_id, h_ts) references public.mx_$t (id, ts))" >/dev/null
done
q "insert into public.mx_a select g, now() - g * interval '20 hours', g * 10 from generate_series(1, 3) g" >/dev/null
q "insert into public.mx_a_ref select 1, id, ts from public.mx_a where id = 2" >/dev/null
q "insert into public.mx_b values (7, now() - interval '3 days', 70), (8, now() - interval '2 hours', 80)" >/dev/null
q "insert into public.mx_b_ref select 5, id, ts from public.mx_b where id = 8" >/dev/null
q "insert into public.mx_c select g, now() - g * interval '20 hours', g * 10 from generate_series(1, 3) g" >/dev/null
q "insert into public.mx_c_ref select 1, id, ts from public.mx_c where id = 2" >/dev/null
q "call pgpm.from_hypertable_copy('public.mx_b', 'ts')" >/dev/null

state() {   # hypertable? / incoming key present? / registered? / which rows
  q "select (select count(*) from timescaledb_information.hypertables where hypertable_name = '$1')
            || '/' || (select count(*) from pg_constraint where conname = '$1_ref_fk' and confrelid = 'public.$1'::regclass)
            || '/' || (select count(*) from pgpm.config where parent_table = to_regclass('public.$1'))
            || '/' || (select string_agg(id::text, ',' order by id) from public.$1)"
}

check "LIVENESS: mx_a, mx_b are hypertables, each referenced by its key, unregistered, holding 1,2,3 and 7,8; mx_b's copy holds 7,8" \
  "$(state mx_a) $(state mx_b) $(q "select string_agg(id::text, ',' order by id) from public.mx_b_pgpm_dest")" \
  "1/1/0/1,2,3 1/1/0/7,8 7,8"
check "LIVENESS: transmute itself refuses '1 mon 1 day' on a plain table (the rule the module is to ask first)" \
  "$(q "create table public.plain_mx (ts timestamptz not null, v int); insert into public.plain_mx values (now() - interval '1 hour', 1);" >/dev/null; qe "call pgpm.transmute('public.plain_mx', 'ts', interval '1 mon 1 day')" | grep -c 'mixed month + duration interval unsupported')" "1"

out_a=$(qe "call pgpm.from_hypertable('public.mx_a', 'ts', interval '1 mon 1 day')")
out_b=$(qe "call pgpm.from_hypertable_cutover('public.mx_b', 'ts', interval '1 mon 1 day', p_predrain => false)")
echo "$out_a" | grep -m1 ERROR | cut -c1-220 | sed 's/^/# a: /'
echo "$out_b" | grep -m1 ERROR | cut -c1-220 | sed 's/^/# b: /'
check "LIVENESS: both '1 mon 1 day' calls ended in a pg_partition_magician refusal" \
  "$(echo "$out_a" | grep -c 'ERROR:  pg_partition_magician:')/$(echo "$out_b" | grep -c 'ERROR:  pg_partition_magician:')" "1/1"

check "from_hypertable refused '1 mon 1 day' in the module's pre-swap words (cannot migrate hypertable ... mixed month + duration interval unsupported)" \
  "$(echo "$out_a" | grep -c 'cannot migrate hypertable mx_a with p_interval 1 mon 1 day -- .*mixed month + duration interval unsupported')" "1"
check "from_hypertable refused '1 mon 1 day' before its copy: mx_a is still a hypertable, its incoming key in place, unregistered, holding 1,2,3" \
  "$(state mx_a)" "1/1/0/1,2,3"
check "from_hypertable_cutover refused '1 mon 1 day' in the module's pre-swap words" \
  "$(echo "$out_b" | grep -c 'cannot migrate hypertable mx_b with p_interval 1 mon 1 day -- .*mixed month + duration interval unsupported')" "1"
check "from_hypertable_cutover refused '1 mon 1 day' before its swap: mx_b is still a hypertable, its incoming key in place, unregistered, holding 7,8" \
  "$(state mx_b)" "1/1/0/7,8"

out_n=$(qe "call pgpm.from_hypertable('public.mx_c', 'ts', interval '1 mon -40 days')")
echo "$out_n" | grep -m1 ERROR | cut -c1-220 | sed 's/^/# c: /'
check "LIVENESS: the '1 mon -40 days' call on mx_c was refused" \
  "$(echo "$out_n" | grep -c 'ERROR:  pg_partition_magician:')" "1"
check "'1 mon -40 days' is refused as a mixed step, not by the frontier check with a remedy that deletes the newest rows" \
  "$(echo "$out_n" | grep -c 'mixed month + duration interval unsupported')/$(echo "$out_n" | grep -c 'Delete or correct the rows')" "1/0"

q "call pgpm.from_hypertable('public.mx_c', 'ts', interval '1 month', p_obtain => 2, p_paused => true)" >/dev/null 2>&1
check "LIVENESS: the control mx_c migrates with a pure month step: partitioned, registered, its key back, holding 1,2,3" \
  "$(q "select (select relkind::text from pg_class where oid = 'public.mx_c'::regclass)
              || '/' || (select count(*) from pgpm.config where parent_table = 'public.mx_c'::regclass)
              || '/' || (select count(*) from pg_constraint where conname = 'mx_c_ref_fk' and confrelid = 'public.mx_c'::regclass)
              || '/' || (select string_agg(id::text, ',' order by id) from public.mx_c)")" "p/1/1/1,2,3"
exit $fail
